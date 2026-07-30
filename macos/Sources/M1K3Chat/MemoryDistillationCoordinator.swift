//
//  MemoryDistillationCoordinator.swift
//  M1K3Chat
//
//  Distilled facts → memory items, deduped twice on the way in:
//  1. EXACT — sourceRef = sha256 of the normalized fact; DocumentIngester
//     already no-ops on an existing sourceRef, so the same fact re-distilled
//     across sessions collapses to one row for free, forever.
//  2. SEMANTIC — embed the fact, vector-search stored memories, skip when a
//     near-duplicate (cosine ≥ 0.90) already exists. Catches paraphrases the
//     hash can't ("Kev's sister is Aoife" / "Aoife is Kev's sister").
//
//  Signed: Kev + claude-fable-5, 2026-06-12, Confidence 0.85 (mechanism
//  test-pinned; the 0.90 dedupe bar is an empirical starting point —
//  refine from MEMEVAL self-similarity stats if it over/under-merges).
//  Prior: Unknown

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
    func writeDistilledFact(_ text: String, kind: DistilledFactKind, embedding: [Float]) async throws
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

    public init(
        distiller: any MemoryDistilling,
        ingester: DocumentIngester,
        store: KnowledgeStore,
        embedder: any EmbeddingService,
        graph: (any DistilledFactGraphWriting)? = nil
    ) {
        self.distiller = distiller
        self.ingester = ingester
        self.store = store
        self.embedder = embedder
        self.graph = graph
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
            // Embed ONCE: the same vector gates semantic dedup AND seeds the graph
            // node, so the dual-write costs no extra embed.
            let vector = await embed(fact.text)
            if let vector, try hasSemanticDuplicate(vector) {
                Self.log.debug("skip (semantic dup): \(LogPreview.preview(fact.text, max: 60), privacy: .public)")
                continue
            }
            let result = try await ingester.ingest(
                title: Self.title(for: fact.text),
                text: fact.text,
                sourceRef: Self.factSourceRef(fact.text),
                kind: .memory,
                source: .distilled
            )
            if result.wasDeduped {
                Self.log.debug("skip (exact dup): \(LogPreview.preview(fact.text, max: 60), privacy: .public)")
                continue
            }
            written += 1
            Self.log.info("remembered: \(LogPreview.preview(fact.text, max: 80), privacy: .public)")
            await dualWriteToGraph(fact, vector: vector)
        }
        Self.log.info("distillation wrote \(written)/\(facts.count) fact(s)")
        return written
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

    private func hasSemanticDuplicate(_ vector: [Float]) throws -> Bool {
        // limit 20, not 5: searchVector ranks across ALL kinds, and a stack of
        // similar document chunks would crowd a true memory duplicate out of a
        // narrow top-K before the kind filter ever saw it.
        let near = try store.searchVector(queryVector: vector, limit: 20)
        return near.contains {
            $0.kind == .memory && ($0.similarity ?? 0) >= Self.semanticDedupeThreshold
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
