//
//  StyleIngestProbeTests.swift
//  M1K3MemoryChatBridgeTests
//
//  #699: MEMSTAT's style ingest probe must see the axis fix. The old probe wrote untyped `.note`
//  facts with no graph through `distillAndStore`, so a style correction under the 0.95 twin bar
//  read "both live" whatever the live writer does. `StyleIngestProbe` writes the pair the way the
//  app's live writer does (a `.style` fact through `store`, a graph adapter over an in-memory
//  MemoryStore) and reads the outcome off BOTH stores, plus the style line the persona would carry.
//
//  `ApartEmbedder` (StyleAxisSupersedeTests) keeps the twin bar out of it, so a superseded here is
//  the axis rule's; the hashing embedder covers the twin path.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85. Prior: none (new file).
//

import Foundation
@testable import M1K3Chat
@testable import M1K3Knowledge
@testable import M1K3MemoryChatBridge
import Testing

struct StyleIngestProbeTests {
    @Test(
        "each MEMSTAT style correction reads superseded, and the style line says only the correction",
        arguments: ContradictionEvalFixtures.styleCorrections
    )
    func correctionReadsSuperseded(pair: ContradictionEvalFixtures.Pair) async throws {
        let result = try await StyleIngestProbe.run(pair, embedder: ApartEmbedder())
        #expect(result.outcome == .superseded, "\(pair.prior) -> \(pair.revision)")
        #expect(result.liveStylesNewestFirst == [pair.revision])
        #expect(result.styleLine == pair.revision)
    }

    @Test("each style compatible reads both live, newest first on the line",
          arguments: ContradictionEvalFixtures.styleCompatibles)
    func compatibleReadsBothLive(pair: ContradictionEvalFixtures.Pair) async throws {
        let result = try await StyleIngestProbe.run(pair, embedder: ApartEmbedder())
        #expect(result.outcome == .bothLive, "\(pair.prior) -> \(pair.revision)")
        #expect(result.liveStylesNewestFirst == [pair.revision, pair.prior])
    }

    @Test("the 0.982 order pair under the hashing embedder reads superseded through the twin path")
    func twinPathReadsSuperseded() async throws {
        let pair = ContradictionEvalFixtures.Pair(
            prior: "The user wants the code before the explanation.",
            revision: "The user wants the explanation before the code."
        )
        let result = try await StyleIngestProbe.run(pair, embedder: HashingEmbeddingService())
        #expect(result.outcome == .superseded)
        #expect(result.liveStylesNewestFirst == [pair.revision])
    }

    @Test("a repeat of the same words is the exact dedupe: eaten, one row live")
    func repeatReadsEaten() async throws {
        let ask = "The user prefers short answers."
        let result = try await StyleIngestProbe.run(.init(prior: ask, revision: ask), embedder: ApartEmbedder())
        #expect(result.outcome == .eaten)
        #expect(result.liveStylesNewestFirst == [ask])
    }

    @Test(
        "the outcome reads both stores, and says so when they disagree",
        arguments: [
            (true, true, StyleIngestProbe.Outcome.superseded),
            (false, false, .bothLive),
            (true, false, .divergent),
            (false, true, .divergent),
        ]
    )
    func outcomeReadsBothStores(graphRetired: Bool, corpusRetired: Bool, expected: StyleIngestProbe.Outcome) {
        #expect(StyleIngestProbe.outcome(graphRetired: graphRetired, corpusRetired: corpusRetired) == expected)
    }
}
