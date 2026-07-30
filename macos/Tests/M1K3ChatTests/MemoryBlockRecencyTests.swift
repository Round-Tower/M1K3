//
//  MemoryBlockRecencyTests.swift
//  M1K3ChatTests
//
//  Tier 1 (scratch/dream-cycle/SPEC.md): the memory block gains read-time
//  honesty — each fact carries when it was learned, newest first, so the
//  model resolves contradictions with the signal a human would use.
//  Undated hits (createdAt nil — old payloads, fixtures) render EXACTLY the
//  pre-Tier-1 bare line, so the byte-pinned no-date behaviour never moves.
//
//  Signed: Kev + claude-fable-5, 2026-07-30, Confidence 0.9. Prior:
//  MemoryGroundingTests (Kev + claude-fable-5).
//

import Foundation
@testable import M1K3Chat
import M1K3Knowledge
import Testing

struct MemoryBlockRecencyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let tools: Set<String> = ["search_knowledge"]

    private func memoryHit(_ fact: String, daysAgo: Double? = nil) -> ChunkHit {
        ChunkHit(
            chunkID: UUID(), itemID: UUID(), itemTitle: fact, kind: .memory,
            heading: nil, content: fact,
            createdAt: daysAgo.map { now.addingTimeInterval(-$0 * 86400) }
        )
    }

    @Test("the block header carries the conflict-resolution clause")
    func conflictClause() {
        let out = AgentRAGResponder.grounding(
            chunks: [], memories: [memoryHit("Kev lives in Ardmore.", daysAgo: 3)],
            toolNames: tools, style: .native, now: now
        )
        #expect(out.contains("where facts conflict, trust the most recently learned"))
    }

    @Test("a dated memory renders its learned-recency prefix")
    func datedFactCarriesRecency() {
        let out = AgentRAGResponder.grounding(
            chunks: [], memories: [memoryHit("Kev lives in Ardmore.", daysAgo: 3)],
            toolNames: tools, style: .native, now: now
        )
        #expect(out.contains("- (learned 3 days ago) Kev lives in Ardmore."))
    }

    @Test("memories sort newest-first regardless of retrieval order")
    func newestFirst() throws {
        let out = AgentRAGResponder.grounding(
            chunks: [],
            memories: [
                memoryHit("Kev lives in Dublin.", daysAgo: 400),
                memoryHit("Kev lives in Ardmore.", daysAgo: 1),
            ],
            toolNames: tools, style: .native, now: now
        )
        let newer = try #require(out.range(of: "(learned yesterday) Kev lives in Ardmore."))
        let older = try #require(out.range(of: "(learned a year ago) Kev lives in Dublin."))
        #expect(newer.lowerBound < older.lowerBound)
    }

    @Test("an undated memory renders the bare pre-Tier-1 line")
    func undatedStaysBare() {
        let out = AgentRAGResponder.grounding(
            chunks: [], memories: [memoryHit("Prefers metric units.")],
            toolNames: tools, style: .native, now: now
        )
        #expect(out.contains("- Prefers metric units."))
        #expect(!out.contains("(learned"))
    }

    @Test("undated memories sort after dated ones")
    func undatedSortLast() throws {
        let out = AgentRAGResponder.grounding(
            chunks: [],
            memories: [
                memoryHit("Prefers metric units."),
                memoryHit("Kev lives in Ardmore.", daysAgo: 2),
            ],
            toolNames: tools, style: .native, now: now
        )
        let dated = try #require(out.range(of: "(learned 2 days ago) Kev lives in Ardmore."))
        let bare = try #require(out.range(of: "- Prefers metric units."))
        #expect(dated.lowerBound < bare.lowerBound)
    }

    @Test("both prompt styles carry the dated line")
    func bothStyles() {
        for style in [AgentRAGResponder.PromptStyle.react, .native] {
            let out = AgentRAGResponder.grounding(
                chunks: [], memories: [memoryHit("Kev lives in Ardmore.", daysAgo: 0)],
                toolNames: tools, style: style, now: now
            )
            #expect(out.contains("- (learned today) Kev lives in Ardmore."))
        }
    }
}
