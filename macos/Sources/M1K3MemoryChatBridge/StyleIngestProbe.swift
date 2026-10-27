//
//  StyleIngestProbe.swift
//  M1K3MemoryChatBridge
//
//  #699: MEMSTAT's style-correction ingest probe, wired the way the app's LIVE writer is.
//  The old probe (MemStatStage's `ingestOutcome`) wrote untyped `.note` facts through
//  `distillAndStore` with no graph: right for the contradiction / compatible / restatement
//  classes, which it still measures unchanged, but blind to the axis supersede, which only
//  runs for a `.style` fact with a graph wired. Sending a style pair through `propose` would
//  not help either: StyleAskFence passes only an ask the user typed, and the probe has none.
//  So a pair goes in as two `.style` facts through `store` (the one write path, the caller
//  owning attribution, as an OKF import does), over a fresh in-memory corpus and graph, and
//  the outcome is read off BOTH stores, with the style line the persona would then carry.
//
//  A probe, not a feature: the app's SelfTest MEMSTAT arm is its only caller, with the real
//  embedder; StyleIngestProbeTests pins it with the test embedders.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85 (the outcome read is pinned; what
//  the real embedder does to each pair is MEMSTAT's to say). Prior: none (new file).
//

import Foundation
import M1K3Chat
import M1K3Inference
import M1K3Knowledge
import M1K3Memory

public enum StyleIngestProbe {
    public enum Outcome: String, Sendable {
        /// The prior left both stores: its graph node superseded, its corpus twin out of retrieval.
        case superseded
        /// The revision wrote and the prior stayed live in both stores.
        case bothLive = "both live"
        /// The revision wrote nothing (the exact dedupe took it).
        case eaten
        /// The graph and the corpus disagree about the prior (the audited divergence path).
        case divergent
        /// The prior itself did not write.
        case seedFailed = "seed failed"
    }

    public struct Result: Sendable {
        public let outcome: Outcome
        /// The live `.style` rows after the revision, newest first: what the persona reads.
        public let liveStylesNewestFirst: [String]

        /// The style line the persona would carry after the pair (its text, without the lead-in),
        /// or nil when no style row is live.
        public var styleLine: String? {
            UserStyleBlock.render(newestFirst: liveStylesNewestFirst, cap: M1K3Persona.styleCharacterCap)
        }
    }

    /// Store `pair.prior` then `pair.revision` as stated styles through the live writer's path
    /// and read what happened to the prior.
    public static func run(
        _ pair: ContradictionEvalFixtures.Pair, embedder: any EmbeddingService
    ) async throws -> Result {
        let corpus = try KnowledgeStore() // in-memory, discarded per pair
        let graph = try MemoryStore() // in-memory, discarded per pair
        // The live writer's defaults: it revives, and it retires a live style row.
        let coordinator = MemoryDistillationCoordinator(
            distiller: NothingDistilled(),
            ingester: DocumentIngester(store: corpus, embedder: embedder),
            store: corpus,
            embedder: embedder,
            graph: DistilledFactGraphAdapter(store: graph)
        )
        guard try await coordinator.store([DistilledFact(text: pair.prior, kind: .style)]) == 1 else {
            return try Result(outcome: .seedFailed, liveStylesNewestFirst: graph.liveStyleTexts())
        }
        let written = try await coordinator.store([DistilledFact(text: pair.revision, kind: .style)])
        let live = try graph.liveStyleTexts()
        guard written == 1 else { return Result(outcome: .eaten, liveStylesNewestFirst: live) }

        let priorNode = try graph.allMemories(includeSuperseded: true, limit: 64).first { $0.text == pair.prior }
        let priorRef = MemoryDistillationCoordinator.factSourceRef(pair.prior)
        let priorKind = try corpus.itemID(forSourceRef: priorRef).flatMap { try corpus.item(id: $0)?.kind }
        return Result(
            outcome: outcome(
                graphRetired: priorNode?.supersededBy != nil, corpusRetired: priorKind == .memorySuperseded
            ),
            liveStylesNewestFirst: live
        )
    }

    /// The prior's fate from each store's view: both retired, both live, or a disagreement.
    static func outcome(graphRetired: Bool, corpusRetired: Bool) -> Outcome {
        switch (graphRetired, corpusRetired) {
        case (true, true): .superseded
        case (false, false): .bothLive
        default: .divergent
        }
    }
}

/// The probe calls `store` directly, so the distiller is never asked.
private struct NothingDistilled: MemoryDistilling {
    func distill(turns _: [ChatTurn]) async throws -> [DistilledFact] {
        []
    }
}
