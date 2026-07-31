//
//  MemoryDistillationCoordinator.swift
//  M1K3Chat
//
//  Distilled facts → memory items, deduped twice on the way in:
//  1. EXACT — sourceRef = sha256 of the normalized fact; DocumentIngester
//     already no-ops on an existing sourceRef, so the same fact re-distilled
//     across sessions collapses to one row for free, forever.
//  2. SEMANTIC — embed the fact, vector-search stored memories. Since the
//     Tier-2 write-time repair (2026-07-30) a ≥ 0.90 twin is SUPERSEDED
//     rather than the new fact discarded: the MEMSTAT census proved the old
//     skip silently ate 3/10 corrections (the Dublin→Ardmore class), and a
//     restatement superseding its twin is only a harmless refresh. The live
//     set stays deduplicated either way — exactly one row per fact survives
//     in retrieval.
//
//  Signed: Kev + claude-fable-5, 2026-06-12, Confidence 0.85 (mechanism
//  test-pinned; the 0.90 dedupe bar is an empirical starting point —
//  refine from MEMEVAL self-similarity stats if it over/under-merges).
//  Prior: Unknown
//  Review: Kev + claude-fable-5, 2026-07-30 — Tier-2 write-time repair:
//  supersede-at-the-bar, un-supersede-on-reassert, corpus-twin re-kind with
//  the M2 divergence audit (scratch/dream-cycle/SPEC.md §2, evidence in
//  MEMSTAT-RESULTS.md).

import CryptoKit
import Foundation
import M1K3Agent
import M1K3Inference
import M1K3Knowledge
import os

/// The temporal memory GRAPH write seam, kept as a protocol so M1K3Chat stays
/// free of a hard M1K3Memory dependency (the app wires the concrete MemoryStore
/// adapter). This is THE fix for the divergent stores: distilled facts now reach
/// the graph through the same coordinator that writes the corpus, instead of the
/// corpus-only path that left the graph empty and `related_memory` edgeless.
public protocol DistilledFactGraphWriting: Sendable {
    /// Persist a newly distilled fact as a node in the memory graph, carrying
    /// the distiller's classification (the bridge maps it onto MemoryKind).
    /// Best-effort: the corpus write is the source of truth, so a graph-write
    /// failure must never fail distillation.
    ///
    /// Tier 2 (dream-cycle): `superseding` carries the FACT TEXT of the live
    /// node this write corrects — the seam stays string-typed (text is the
    /// join key the dual-write already shares across stores), so M1K3Chat
    /// never learns graph UUIDs. Nil = a plain insert.
    func writeDistilledFact(
        _ text: String, kind: DistilledFactKind, embedding: [Float], superseding oldFactText: String?
    ) async throws

    /// Un-supersede-on-reassert (Tier 2, spec finding #8): the user re-stated
    /// a fact whose graph node is superseded. Writes a fresh node with `text`
    /// that supersedes the chain's LIVE head, and returns that supplanted
    /// head's text so the caller can re-kind its corpus twin out of
    /// retrieval. Nil when no superseded chain matched (degraded to a plain
    /// write).
    func reviveFact(_ text: String, kind: DistilledFactKind, embedding: [Float]) async throws -> String?
}

public extension DistilledFactGraphWriting {
    /// Pre-Tier-2 convenience — a plain insert.
    func writeDistilledFact(_ text: String, kind: DistilledFactKind, embedding: [Float]) async throws {
        try await writeDistilledFact(text, kind: kind, embedding: embedding, superseding: nil)
    }
}

public struct MemoryDistillationCoordinator: Sendable {
    private static let log = Logger(subsystem: M1K3Log.subsystem, category: "memory-distill")
    /// Cosine above which a stored memory counts as "already known".
    /// Public so the MEMSTAT census (scratch/dream-cycle/SPEC.md Tier 0)
    /// reports against the LIVE bar, never a copied constant.
    public static let semanticDedupeThreshold: Float = 0.90
    static let maxTitleLength = 60

    private let distiller: any MemoryDistilling
    private let ingester: DocumentIngester
    private let store: KnowledgeStore
    private let embedder: any EmbeddingService
    /// Optional: nil keeps the legacy corpus-only behaviour (tests, any caller
    /// that hasn't wired the graph yet).
    private let graph: (any DistilledFactGraphWriting)?
    /// The corpus-twin kind transition (Tier 2). Injectable so the
    /// divergence-audit path (a re-kind failing AFTER the graph committed —
    /// spec fixture #9) is testable; nil uses `store.setKind` directly.
    private let rekind: (@Sendable (UUID, KnowledgeKind) throws -> Bool)?
    /// Receives one line per corpus/graph divergence (IDs + kinds only,
    /// never fact text) — the M2 typed-audit hook. The same line always
    /// goes to the security-relevant `.error` log regardless.
    private let auditSink: (@Sendable (String) -> Void)?

    public init(
        distiller: any MemoryDistilling,
        ingester: DocumentIngester,
        store: KnowledgeStore,
        embedder: any EmbeddingService,
        graph: (any DistilledFactGraphWriting)? = nil,
        rekind: (@Sendable (UUID, KnowledgeKind) throws -> Bool)? = nil,
        auditSink: (@Sendable (String) -> Void)? = nil
    ) {
        self.distiller = distiller
        self.ingester = ingester
        self.store = store
        self.embedder = embedder
        self.graph = graph
        self.rekind = rekind
        self.auditSink = auditSink
    }

    /// Distill the slice and store what's new. Returns the number of facts
    /// actually written (dedupe skips don't count). Rethrows distiller
    /// failure so the caller withholds the watermark and retries the slice.
    @discardableResult
    public func distillAndStore(turns: [ChatTurn]) async throws -> Int {
        let facts = try await distiller.distill(turns: turns)
        guard !facts.isEmpty else {
            Self.log.info("distilled 0 facts from \(turns.count) turn(s)")
            return 0
        }
        var written = 0
        for fact in facts {
            // Embed ONCE: the same vector finds the semantic twin AND seeds
            // the graph node, so the repair costs no extra embed.
            let vector = await embed(fact.text)
            // Tier 2 (dream-cycle): a ≥ bar twin is SUPERSEDED, never eaten.
            // MEMSTAT (2026-07-30) measured 3/10 corrections silently
            // discarded by the old `continue`, and no cosine bar separates
            // correction from restatement — while a misclassified restatement
            // supersede is only a harmless refresh. Compatibles never reach
            // the bar (measured max 0.768), so false supersedes stay
            // structurally impossible at this threshold.
            let twin = try vector.flatMap { try semanticTwin($0) }

            let result = try await ingester.ingest(
                title: Self.title(for: fact.text),
                text: fact.text,
                sourceRef: Self.factSourceRef(fact.text),
                kind: .memory,
                source: .distilled
            )
            if result.wasDeduped {
                // Exact re-assertion. If the existing row was re-kinded out of
                // retrieval by an earlier supersede, this is the user REPAIR —
                // revive it (spec finding #8). A live row is a true duplicate.
                if try store.item(id: result.itemID)?.kind == .memorySuperseded {
                    try await revive(fact, itemID: result.itemID, vector: vector)
                    written += 1
                } else {
                    Self.log.debug("skip (exact dup): \(LogPreview.preview(fact.text, max: 60), privacy: .public)")
                }
                continue
            }
            written += 1
            if let twin {
                await supersede(twin, with: fact, newItemID: result.itemID, vector: vector)
            } else {
                Self.log.info("remembered: \(LogPreview.preview(fact.text, max: 80), privacy: .public)")
                await dualWriteToGraph(fact, vector: vector)
            }
        }
        Self.log.info("distillation wrote \(written)/\(facts.count) fact(s)")
        return written
    }

    // MARK: - Tier 2: write-time repair

    /// The new fact corrects (or restates) `twin`: graph gets a supersede
    /// write joined by fact text, then the twin's corpus row leaves retrieval
    /// via the `.memorySuperseded` re-kind. Order is deliberate — graph
    /// commit FIRST, corpus transition second — so a failure between the two
    /// lands in the audited divergence path (spec fixture #9), never as a
    /// live corpus row whose graph node is secretly superseded going
    /// unnoticed.
    private func supersede(
        _ twin: ChunkHit, with fact: DistilledFact, newItemID: UUID, vector: [Float]?
    ) async {
        if let graph, let vector {
            do {
                try await graph.writeDistilledFact(
                    fact.text, kind: fact.kind, embedding: vector, superseding: twin.content
                )
            } catch {
                Self.log.notice("graph supersede failed (corpus write stands): \(error.localizedDescription, privacy: .public)")
            }
        }
        transitionCorpusTwin(itemID: twin.itemID, context: "supersede")
        recordSupersededLink(from: twin.itemID, to: newItemID)
        Self.log.notice("memory superseded: 1 fact corrected at write time")
    }

    // MARK: - The corpus supersede ledger

    /// CORPUS-side record of "who corrected whom" (meta table, IDs only).
    /// This — not the graph — is what revive() reads to find the corrector it
    /// must demote: the graph is best-effort/optional (nil for corpus-only
    /// callers, and for the live app whenever memory.sqlite failed to open),
    /// and a repair that depends on it would leave two contradicting live
    /// rows exactly in the degraded state that needs the repair most
    /// (PR #87 review finding 1).
    static func supersededLinkKey(_ itemID: UUID) -> String {
        "memory.superseded-by:\(itemID.uuidString)"
    }

    private func recordSupersededLink(from oldItemID: UUID, to newItemID: UUID) {
        do {
            try store.setMeta(key: Self.supersededLinkKey(oldItemID), value: newItemID.uuidString)
        } catch {
            Self.log.error("supersede-ledger write failed for item \(oldItemID.uuidString, privacy: .public)")
        }
    }

    private func supersededLink(for itemID: UUID) -> UUID? {
        (try? store.meta(key: Self.supersededLinkKey(itemID))).flatMap { $0 }.flatMap(UUID.init(uuidString:))
    }

    /// Exact re-assertion of a superseded fact: the graph writes a fresh node
    /// over the chain's live head, the existing corpus row returns to
    /// retrieval, and the supplanted head's own corpus twin leaves it.
    private func revive(_ fact: DistilledFact, itemID: UUID, vector: [Float]?) async throws {
        if let graph, let vector {
            do {
                // The graph resolves its own chain head; the corpus supplant
                // below deliberately does NOT use this return value — the
                // ledger works graph-less (PR #87 review finding 1).
                _ = try await graph.reviveFact(fact.text, kind: fact.kind, embedding: vector)
            } catch {
                Self.log.notice("graph revive failed (corpus restore proceeds): \(error.localizedDescription, privacy: .public)")
            }
        }
        transitionCorpusTwin(itemID: itemID, to: .memory, context: "revive-restore")
        if let correctorID = supersededLink(for: itemID) {
            transitionCorpusTwin(itemID: correctorID, context: "revive-supplant")
            // Flip the ledger: the demoted corrector can itself be revived.
            recordSupersededLink(from: correctorID, to: itemID)
            try? store.deleteMeta(key: Self.supersededLinkKey(itemID))
        }
        Self.log.notice("memory revived: 1 superseded fact restored by re-assertion")
    }

    /// The corpus-twin kind transition, with the M2 divergence audit: by the
    /// time this runs the GRAPH has already committed, so a failure here means
    /// the two stores disagree — logged at `.error` (IDs + kinds only, never
    /// text) and mirrored to the audit sink. Self-heals on the next
    /// supersede/revive touching the same fact; never throws.
    private func transitionCorpusTwin(
        itemID: UUID, to kind: KnowledgeKind = .memorySuperseded, context: String
    ) {
        let outcome: Bool
        do {
            outcome = try rekind.map { try $0(itemID, kind) } ?? store.setKind(id: itemID, newKind: kind)
        } catch {
            outcome = false
        }
        guard !outcome else { return }
        let line = "memory corpus/graph divergence [\(context)]: item \(itemID.uuidString) "
            + "failed transition to \(kind.rawValue) after graph commit"
        Self.log.error("\(line, privacy: .public)")
        auditSink?(line)
    }

    /// The top live memory twin at/above the dedupe bar, if any.
    private func semanticTwin(_ vector: [Float]) throws -> ChunkHit? {
        // limit 20, not 5: searchVector ranks across ALL kinds, and a stack of
        // similar document chunks would crowd a true memory twin out of a
        // narrow top-K before the kind filter ever saw it.
        try store.searchVector(queryVector: vector, limit: 20).first {
            $0.kind == .memory && ($0.similarity ?? 0) >= Self.semanticDedupeThreshold
        }
    }

    /// Embed for dedup + graph seed. Returns nil (logged) on failure so a
    /// degenerate embedder doesn't silently read as "no duplicates" — the corpus
    /// write still proceeds (fail-open), only dedup + the graph seed are skipped.
    private func embed(_ fact: String) async -> [Float]? {
        do { return try await embedder.embed(fact) } catch {
            Self.log.notice("embed failed — dedup + graph-write skipped: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Mirror a freshly-written fact into the memory graph. Best-effort: a graph
    /// failure is logged, never thrown — the corpus already holds the fact.
    private func dualWriteToGraph(_ fact: DistilledFact, vector: [Float]?) async {
        guard let graph, let vector else { return }
        do { try await graph.writeDistilledFact(fact.text, kind: fact.kind, embedding: vector) } catch {
            Self.log.notice("graph dual-write failed (corpus write stands): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stable identity for the exact-dedupe layer: hash of the normalized
    /// fact, so capitalisation/punctuation variants collapse. Public — the
    /// MCP `remember` path uses the same identity so an agent remembering
    /// the same text twice collapses to one row.
    public static func factSourceRef(_ fact: String) -> String {
        let normalized = MemoryFactNormalizer.normalize(fact)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "memory-fact:\(hex)"
    }

    /// Short facts ARE their titles; long ones cut at a word boundary.
    static func title(for fact: String) -> String {
        guard fact.count > maxTitleLength else { return fact }
        let prefix = fact.prefix(maxTitleLength)
        let cut = prefix.lastIndex(of: " ").map { prefix[..<$0] } ?? prefix
        return String(cut) + "…"
    }
}
