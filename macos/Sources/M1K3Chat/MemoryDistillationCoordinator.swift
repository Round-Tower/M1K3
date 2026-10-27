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
//  Review: Kev + claude-fable-5.1, 2026-09-11, Confidence 0.85 — #284: distillAndStore now
//  applies the DistillationAttribution fence AFTER the parser's own validator + durability
//  filters — a trivial user turn skips the slice before the distiller is even called, and any
//  surviving fact unanchored in the user's own turns is dropped fail-closed (one `.info` line
//  per slice counts the drops).
//  Review: Kev + claude-fable-5.1, 2026-10-10 — the dedupe bar is `EmbedderFloors.dedupe` for the
//  embedder in use (0.90 stays for Qwen and hashing; EmbeddingGemma 2 carries its own), via
//  `semanticDedupeThreshold(for:)`.
//  Review: Kev + claude-fable-5.1, 2026-09-11 (review 10 fold on #288) — `selfNames` is injected
//  like every other collaborator (default: the account's names); tests pass `.none` and stop
//  depending on the machine's user name.
//  Review: Kev + claude-opus-5.5, 2026-10-27 — #699 Phase 1: a `.style` fact must ALSO pass StyleAskFence
//  (one user turn that anchors it reads as a request), because a stored style rides every system prompt;
//  the drops get their own `.info` count. `didWrite` (the `auditSink` closure shape) fires once with the
//  count when a slice wrote anything, so the app re-reads the style rows into the persona. Confidence 0.85.
//  Review: same day — `title(for:)` and `supersededLinkKey(_:)` are public, so the Memories editor's supersede
//  titles the new row and records the revive ledger exactly as `supersede` does. Confidence 0.85.
//  Review: Kev + claude-opus-5.5, 2026-10-27 (pre-push review fold) — the corpus half of a Memories edit moved
//  here from the app as `applyEdit` (it re-implemented this file's supersede without its order, revive or audit):
//  the new wording is ingested FIRST, a same-identity edit moves nothing, an edit back to a retired wording
//  restores it, and a failure is logged and audited by ids. `title(for:)` and `supersededLinkKey(_:)` are
//  internal again. `didWrite` fires from a `defer`, so a slice that wrote facts and then threw still re-reads the
//  style. An asked-for style fact whose exact text is already live under another kind (a pre-#699 preference
//  row) re-files that graph node through the seam's `refileDistilledFact` instead of vanishing as a duplicate.
//  The edit, and the twin transition and ledger it shares with this file, live in MemoryCorpusEdit.swift;
//  the two fences are one `fenceDrop` helper. Confidence 0.85.

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

    /// #699: the fact's text (normalised) is already a live node of another kind, as a pre-#699
    /// store filed "The user prefers short answers." under `preference`. Re-file it as `kind`,
    /// superseding that node (lineage kept). False when none matched or it already is `kind`.
    func refileDistilledFact(_ text: String, as kind: DistilledFactKind, embedding: [Float]) async throws -> Bool
}

public extension DistilledFactGraphWriting {
    /// Pre-Tier-2 convenience — a plain insert.
    func writeDistilledFact(_ text: String, kind: DistilledFactKind, embedding: [Float]) async throws {
        try await writeDistilledFact(text, kind: kind, embedding: embedding, superseding: nil)
    }

    /// A graph that cannot re-file re-files nothing.
    func refileDistilledFact(_: String, as _: DistilledFactKind, embedding _: [Float]) async throws -> Bool {
        false
    }
}

public struct MemoryDistillationCoordinator: Sendable {
    static let log = Logger(subsystem: M1K3Log.subsystem, category: "memory-distill")
    /// Cosine above which a stored memory counts as "already known" — the
    /// embedder's own bar (`EmbedderFloors.dedupe`): 0.90 was measured on
    /// Qwen3-Embedding (compatibles max 0.768); EmbeddingGemma 2's cone sits
    /// higher. MEMSTAT reports against this same lookup, never a copy.
    public static func semanticDedupeThreshold(for embedder: any EmbeddingService) -> Float {
        EmbedderFloors.forFingerprint(embedder.fingerprint).dedupe
    }

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
    /// Fired once, off the main actor, when a `distillAndStore` wrote at least one fact, with
    /// the count (#699), including when a later fact threw after earlier ones landed: the
    /// app's hook to re-read the style rows into the persona. Any write may change them (a
    /// cross-kind supersede included), and a re-read that finds the same rows leaves the
    /// system prompt, and so the prefix cache, as it was.
    private let didWrite: (@Sendable (Int) -> Void)?
    /// The user's own names for the attribution fence — the account's in the
    /// app, `.none` in tests, so a suite never depends on who runs it
    /// (review 10 on #288: a tester surnamed Corkery would have lost "cork").
    private let selfNames: DistillationAttribution.UserNames

    public init(
        distiller: any MemoryDistilling,
        ingester: DocumentIngester,
        store: KnowledgeStore,
        embedder: any EmbeddingService,
        graph: (any DistilledFactGraphWriting)? = nil,
        rekind: (@Sendable (UUID, KnowledgeKind) throws -> Bool)? = nil,
        auditSink: (@Sendable (String) -> Void)? = nil,
        didWrite: (@Sendable (Int) -> Void)? = nil,
        selfNames: DistillationAttribution.UserNames = DistillationAttribution.systemUserNames
    ) {
        self.distiller = distiller
        self.ingester = ingester
        self.store = store
        self.embedder = embedder
        self.graph = graph
        self.rekind = rekind
        self.auditSink = auditSink
        self.didWrite = didWrite
        self.selfNames = selfNames
    }

    /// Distill the slice and store what's new. Returns the number of facts
    /// actually written (dedupe skips don't count). Rethrows distiller
    /// failure so the caller withholds the watermark and retries the slice.
    ///
    /// #284 attribution fence, applied AFTER MemoryFactParser's own validator +
    /// durability filters: a trivial user turn (a bare greeting) never even
    /// reaches the distiller — nothing the user said could anchor anything —
    /// and any surviving fact that shares no real content with something the
    /// user actually said is dropped fail-closed.
    ///
    /// #699: a `.style` fact also needs an explicit ask (`StyleAskFence`): it
    /// renders into every system prompt, so it must come from a request the
    /// user made, never from how they behave.
    @discardableResult
    public func distillAndStore(turns: [ChatTurn]) async throws -> Int {
        guard !DistillationAttribution.userContributionIsTrivial(turns: turns) else {
            Self.log.info("distillation skipped: user contribution trivial (\(turns.count) turn(s))")
            return 0
        }
        let facts = try await distiller.distill(turns: turns)
        guard !facts.isEmpty else {
            Self.log.info("distilled 0 facts from \(turns.count) turn(s)")
            return 0
        }
        let userTurns = turns.filter { $0.role == .user }.map(\.text)
        var dropped: [FenceDrop: Int] = [:]
        var written = 0
        // Fires on the throw path too: facts written before a later one threw are in the stores.
        defer { if written > 0 { didWrite?(written) } }
        for fact in facts {
            if let drop = fenceDrop(fact, userTurns: userTurns) {
                dropped[drop, default: 0] += 1
                continue
            }
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
                if try await reassert(fact, itemID: result.itemID, vector: vector) { written += 1 }
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
        if let count = dropped[.unanchored] {
            Self.log.info("distillation dropped \(count) unanchored fact(s)")
        }
        if let count = dropped[.unasked] {
            Self.log.info("distillation dropped \(count) style fact(s) the user never asked for")
        }
        Self.log.info("distillation wrote \(written)/\(facts.count) fact(s)")
        return written
    }

    /// Why a fence dropped a fact.
    private enum FenceDrop { case unanchored, unasked }

    /// #284's anchor rule, then (#699) the explicit-ask rule a style fact also needs: it
    /// renders into every system prompt. Nil when the fact passes.
    private func fenceDrop(_ fact: DistilledFact, userTurns: [String]) -> FenceDrop? {
        guard DistillationAttribution.isAnchored(fact: fact.text, userTurns: userTurns, selfNames: selfNames) else {
            return .unanchored
        }
        guard fact.kind == .style else { return nil }
        let asked = StyleAskFence.isExplicitAsk(fact: fact.text, userTurns: userTurns, selfNames: selfNames)
        return asked ? nil : .unasked
    }

    /// Exact re-assertion. A superseded row is the user's REPAIR: revive it (spec finding #8).
    /// An asked-for style fact re-files a live row of another kind (#699). Anything else is a
    /// true duplicate. True when it wrote.
    private func reassert(_ fact: DistilledFact, itemID: UUID, vector: [Float]?) async throws -> Bool {
        if try store.item(id: itemID)?.kind == .memorySuperseded {
            try await revive(fact, itemID: itemID, vector: vector)
            return true
        }
        if fact.kind == .style, await refileAsStyle(fact, vector: vector) { return true }
        Self.log.debug("skip (exact dup): \(LogPreview.preview(fact.text, max: 60), privacy: .public)")
        return false
    }

    /// #699: the corpus twin is text-keyed, so it already answers; the graph node is re-filed
    /// as style so the persona reads it. Best-effort: a failure leaves the row as it was.
    private func refileAsStyle(_ fact: DistilledFact, vector: [Float]?) async -> Bool {
        guard let graph, let vector else { return false }
        do {
            let refiled = try await graph.refileDistilledFact(fact.text, as: fact.kind, embedding: vector)
            if refiled { Self.log.notice("memory re-filed: 1 live fact is now a stated style") }
            return refiled
        } catch {
            Self.log.notice("graph re-file failed (the row stands): \(error.localizedDescription, privacy: .public)")
            return false
        }
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

    // MARK: - The corpus supersede ledger (its key and write: MemoryCorpusEdit.swift, shared with the edit)

    private func recordSupersededLink(from oldItemID: UUID, to newItemID: UUID) {
        Self.recordSupersededLink(from: oldItemID, to: newItemID, store: store)
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
        Self.transitionCorpusTwin(
            itemID: itemID, to: kind, context: context, store: store, rekind: rekind, auditSink: auditSink
        )
    }

    /// The top live memory twin at/above the dedupe bar, if any.
    private func semanticTwin(_ vector: [Float]) throws -> ChunkHit? {
        // limit 20, not 5: searchVector ranks across ALL kinds, and a stack of
        // similar document chunks would crowd a true memory twin out of a
        // narrow top-K before the kind filter ever saw it.
        try store.searchVector(queryVector: vector, limit: 20).first {
            $0.kind == .memory && ($0.similarity ?? 0) >= Self.semanticDedupeThreshold(for: embedder)
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
