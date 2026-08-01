//
//  MemoryProvenanceTests.swift
//  M1K3MemoryTests
//
//  The two pure helpers behind the explorable memory surface: classifying a
//  fact's provenance from its `source` string ("you told me" vs "I noticed"),
//  and tracing the supersession history behind a live fact ("how did you learn
//  this?"). Both are pure over Memory values — no store, no embedder — so the
//  view layer can be dumb and this logic is pinned here.
//
//  Signed: Kev + claude-opus-4-8, 2026-07-20, Confidence 0.85 (test-first for
//  the knowledge-graph-as-surface slice). Prior: MemoriesView flat list.

import Foundation
@testable import M1K3Memory
import Testing

struct MemoryProvenanceTests {
    @Test("explicit user authorship classifies as youToldMe")
    func userSourcesAreYouToldMe() {
        #expect(MemoryProvenance(source: "user:settings") == .youToldMe)
        #expect(MemoryProvenance(source: "mcp:remember") == .youToldMe)
        #expect(MemoryProvenance(source: "USER:manual") == .youToldMe) // case-insensitive
    }

    @Test("distilled facts classify as iNoticed")
    func distilledSourcesAreINoticed() {
        #expect(MemoryProvenance(source: "chat:auto-distill") == .iNoticed)
        #expect(MemoryProvenance(source: "distilled") == .iNoticed)
    }

    @Test("unknown sources fall back to remembered, never crash")
    func unknownSourcesAreRemembered() {
        #expect(MemoryProvenance(source: "test") == .remembered)
        #expect(MemoryProvenance(source: "") == .remembered)
    }
}

struct SupersessionHistoryTests {
    private func memory(
        _ text: String, at day: Double, supersededBy: UUID? = nil
    ) -> Memory {
        Memory(
            kind: .profile, text: text, source: "test",
            createdAt: Date(timeIntervalSince1970: day * 86400),
            supersededBy: supersededBy
        )
    }

    @Test("a fact with no corrections is its own single-item history")
    func standaloneFactIsLoneHistory() {
        let m = memory("Kev lives in Cork", at: 3)
        let history = SupersessionChain.history(endingAt: m, in: [m])
        #expect(history.map(\.id) == [m.id])
    }

    @Test("history walks supersededBy backwards, oldest first, ending at the live fact")
    func historyIsOldestFirst() {
        // v3 (live) corrects v2, which corrected v1.
        let v3ID = UUID()
        let v2ID = UUID()
        var v1 = memory("Kev lives in Dublin", at: 1)
        var v2 = memory("Kev lives in Galway", at: 2)
        let v3 = Memory(id: v3ID, kind: .profile, text: "Kev lives in Cork",
                        source: "test",
                        createdAt: Date(timeIntervalSince1970: 3 * 86400))
        v1.supersededBy = v2ID
        v2 = Memory(id: v2ID, kind: .profile, text: v2.text, source: "test",
                    createdAt: v2.createdAt, supersededBy: v3ID)

        let history = SupersessionChain.history(endingAt: v3, in: [v3, v1, v2])
        #expect(history.map(\.text) == [
            "Kev lives in Dublin", "Kev lives in Galway", "Kev lives in Cork",
        ])
    }

    @Test("a supersession cycle terminates (visited guard)")
    func cycleTerminates() {
        let aID = UUID(), bID = UUID()
        let a = Memory(id: aID, kind: .note, text: "A", source: "test",
                       createdAt: Date(timeIntervalSince1970: 86400), supersededBy: bID)
        let b = Memory(id: bID, kind: .note, text: "B", source: "test",
                       createdAt: Date(timeIntervalSince1970: 2 * 86400), supersededBy: aID)
        // Should not hang; both nodes appear exactly once.
        let history = SupersessionChain.history(endingAt: b, in: [a, b])
        #expect(Set(history.map(\.id)) == [aID, bID])
    }
}
