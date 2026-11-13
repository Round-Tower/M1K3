//
//  GroundedSearchPageTests.swift
//  M1K3KnowledgeTests
//
//  The explicit-search page: `limit` is the caller's total, and the order is
//  relevance, not "every document, then every memory". Found live 2026-11-13
//  through the Claude Code plugin: search_knowledge(limit: 3) returned four
//  results, and a figure caption from an unrelated paper sat above the memory
//  whose title matched the query almost word for word.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-13, Confidence 0.85 (pure ordering
//  over literal hits; the live ranking on Gemma vectors is verify-by-launch).
//  Prior: none (new file).
//

import Foundation
@testable import M1K3Knowledge
import Testing

struct GroundedSearchPageTests {
    private static let floors = EmbedderFloors(
        chunk: 0.70, memory: 0.67, edge: 0.75, dedupe: 0.95, forgetSuggestion: 0.67
    )

    private func hit(_ title: String, _ kind: KnowledgeKind, _ similarity: Float?) -> ChunkHit {
        ChunkHit(
            chunkID: UUID(), itemID: UUID(), itemTitle: title, kind: kind,
            heading: nil, content: title, similarity: similarity
        )
    }

    private func page(_ knowledge: [ChunkHit], _ memories: [ChunkHit], limit: Int) -> [String] {
        GroundedSearch.page(knowledge: knowledge, memories: memories, limit: limit, floors: Self.floors)
            .map(\.itemTitle)
    }

    @Test("the page never holds more than limit hits, however many each lane kept")
    func limitIsTheTotal() {
        let knowledge = [hit("d1", .document, 0.80), hit("d2", .document, 0.78), hit("d3", .document, 0.75)]
        let memories = [hit("m1", .memory, 0.85), hit("m2", .memory, 0.80), hit("m3", .memory, 0.70)]
        #expect(page(knowledge, memories, limit: 3).count == 3)
        #expect(page(knowledge, memories, limit: 1).count == 1)
        #expect(page(knowledge, memories, limit: 10).count == 6)
    }

    @Test("a memory far above its floor outranks a document that barely cleared its own")
    func strongMemoryBeatsWeakDocument() {
        let knowledge = [hit("attention figure caption", .document, 0.71)]
        let memories = [hit("exact title match", .memory, 0.88), hit("second chunk", .memory, 0.80)]
        #expect(page(knowledge, memories, limit: 3) == ["exact title match", "second chunk", "attention figure caption"])
    }

    @Test("each lane is scored against its own floor, so a short fact is not punished for embedding lower")
    func marginsAreKindAware() {
        // 0.75 − 0.67 (memory floor) = 0.08 beats 0.76 − 0.70 (chunk floor) = 0.06.
        let knowledge = [hit("doc", .document, 0.76)]
        let memories = [hit("fact", .memory, 0.75)]
        #expect(page(knowledge, memories, limit: 2) == ["fact", "doc"])
    }

    @Test("a lane that kept something keeps one seat: documents cannot crowd every memory off the page")
    func eachLaneKeepsASeat() {
        let knowledge = [hit("d1", .document, 0.95), hit("d2", .document, 0.94), hit("d3", .document, 0.93)]
        let memories = [hit("m1", .memory, 0.68)]
        #expect(page(knowledge, memories, limit: 2) == ["d1", "m1"])
        // …and the other way round.
        let facts = [hit("m1", .memory, 0.95), hit("m2", .memory, 0.94), hit("m3", .memory, 0.93)]
        #expect(page([hit("d1", .document, 0.71)], facts, limit: 2) == ["m1", "d1"])
    }

    @Test("with one seat the best hit takes it")
    func limitOne() {
        let knowledge = [hit("doc", .document, 0.72)]
        let memories = [hit("fact", .memory, 0.90)]
        #expect(page(knowledge, memories, limit: 1) == ["fact"])
    }

    @Test("an unscored keyword stand-in keeps its lane's seat and sorts last")
    func keywordStandInSurvives() {
        // HashingKeywordLane admits one BM25 chunk with no cosine at all.
        let knowledge = [hit("keyword chunk", .document, nil)]
        let memories = [hit("m1", .memory, 0.80), hit("m2", .memory, 0.75), hit("m3", .memory, 0.70)]
        #expect(page(knowledge, memories, limit: 3) == ["m1", "m2", "keyword chunk"])
    }

    @Test("equal margins keep the lanes' own order, documents first")
    func tiesAreStable() {
        // Floors and cosines chosen so the two margins are the SAME Float (0.25): only the
        // tie-break decides, and a memory listed first in the input would win without it.
        let floors = EmbedderFloors(chunk: 0.5, memory: 0.25, edge: 0.75, dedupe: 0.95, forgetSuggestion: 0.25)
        #expect(Float(0.75) - floors.chunk == Float(0.5) - floors.memory)
        let knowledge = [hit("d1", .document, 0.75), hit("d2", .document, 0.75)]
        let memories = [hit("m1", .memory, 0.5), hit("m2", .memory, 0.5)]
        let titles = GroundedSearch.page(knowledge: knowledge, memories: memories, limit: 4, floors: floors)
            .map(\.itemTitle)
        #expect(titles == ["d1", "d2", "m1", "m2"])
    }

    @Test("on hashing floors the lanes take turns: a stray memory's margin cannot outrank a true chunk")
    func hashingInterleaves() {
        // Measured (EmbedderFloors.hashing): memory noise reaches 0.408 over a 0.10 floor; the
        // weakest true chunk is 0.402 over 0.35. By margin the page would open with two strays.
        let knowledge = [hit("true chunk", .document, 0.402)]
        let memories = [hit("stray 1", .memory, 0.40), hit("stray 2", .memory, 0.30)]
        let titles = GroundedSearch.page(knowledge: knowledge, memories: memories, limit: 2, floors: .hashing)
            .map(\.itemTitle)
        #expect(titles == ["true chunk", "stray 1"])
        let wide = GroundedSearch.page(knowledge: knowledge, memories: memories, limit: 5, floors: .hashing)
        #expect(wide.map(\.itemTitle) == ["true chunk", "stray 1", "stray 2"])
    }

    @Test("a zero or negative limit is an empty page, not a trap")
    func degenerateLimits() {
        let knowledge = [hit("doc", .document, 0.80)]
        #expect(page(knowledge, [], limit: 0).isEmpty)
        #expect(page(knowledge, [], limit: -4).isEmpty)
        #expect(page([], [], limit: 5).isEmpty)
    }
}
