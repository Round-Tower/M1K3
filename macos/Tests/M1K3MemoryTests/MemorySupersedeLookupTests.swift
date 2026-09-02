//
//  MemorySupersedeLookupTests.swift
//  M1K3MemoryTests
//
//  Tier 2 (scratch/dream-cycle/SPEC.md): the store reads the write-time
//  repair path needs — exact-text lookup of the live node a correction
//  supersedes, chain-walk from a superseded text to its live successor
//  (the un-supersede-on-reassert join), and the `related(to:)` superseded
//  filter (spec finding #7: today any supersede write ships the graph into
//  split visibility because traversal ignores `superseded_by`).
//
//  Signed: Kev + claude-fable-5, 2026-07-30, Confidence 0.9. Prior:
//  MemoryStoreTests (Kev + claude-opus-4-8).
//

import Foundation
@testable import M1K3Knowledge
@testable import M1K3Memory
import Testing

private struct Fixture {
    let store: MemoryStore
    let embedder = HashingEmbeddingService()

    init() throws {
        store = try MemoryStore()
    }

    @discardableResult
    func remember(
        _ text: String, kind: MemoryKind = .profile, supersedes oldID: UUID? = nil
    ) async throws -> Memory {
        let memory = Memory(kind: kind, text: text, source: "test")
        try store.remember(memory, embedding: await embedder.embed(text), supersedes: oldID)
        return memory
    }
}

struct MemorySupersedeLookupTests {
    @Test("liveMemory(matchingText:) finds the live row by exact text")
    func liveExactMatch() async throws {
        let f = try Fixture()
        let m = try await f.remember("Kev lives in Dublin.")
        let found = try #require(try f.store.liveMemory(matchingText: "Kev lives in Dublin."))
        #expect(found.id == m.id)
    }

    @Test("liveMemory ignores superseded rows and unrelated text")
    func liveExcludesSuperseded() async throws {
        let f = try Fixture()
        let old = try await f.remember("Kev lives in Dublin.")
        try await f.remember("Kev lives in Ardmore.", supersedes: old.id)

        #expect(try f.store.liveMemory(matchingText: "Kev lives in Dublin.") == nil)
        #expect(try f.store.liveMemory(matchingText: "Kev lives in Cork.") == nil)
    }

    @Test("liveSuccessor walks a supersede chain to the live head")
    func successorChainWalk() async throws {
        let f = try Fixture()
        let a = try await f.remember("Kev lives in Dublin.")
        let b = try await f.remember("Kev lives in Cork.", supersedes: a.id)
        let c = try await f.remember("Kev lives in Ardmore.", supersedes: b.id)

        let head = try #require(try f.store.liveSuccessor(ofText: "Kev lives in Dublin."))
        #expect(head.id == c.id)
        #expect(head.text == "Kev lives in Ardmore.")
    }

    @Test("liveSuccessor is nil when no superseded row carries the text")
    func successorAbsent() async throws {
        let f = try Fixture()
        try await f.remember("Kev lives in Ardmore.")
        #expect(try f.store.liveSuccessor(ofText: "Kev lives in Dublin.") == nil)
    }

    @Test("related(to:) no longer returns superseded neighbours")
    func relatedFiltersSuperseded() async throws {
        let f = try Fixture()
        let anchor = try await f.remember("Kev's sister is called Aoife.")
        let stale = try await f.remember("Kev lives in Dublin.")
        let fresh = try await f.remember("Kev lives in Ardmore.", supersedes: stale.id)
        try f.store.link(MemoryEdge(fromID: anchor.id, toID: stale.id, relation: "related"))
        try f.store.link(MemoryEdge(fromID: anchor.id, toID: fresh.id, relation: "related"))

        let related = try f.store.related(to: anchor.id)

        #expect(related.contains { $0.id == fresh.id })
        #expect(!related.contains { $0.id == stale.id })
    }

    @Test("related(to:) does not walk supersedes edges as topical — a corrected fact's neighbours don't leak in")
    func relatedIgnoresSupersedesEdges() async throws {
        let f = try Fixture()
        let old = try await f.remember("Kev works at OldCo.")
        let anchor = try await f.remember("Kev works at NewCo.", supersedes: old.id)
        // A fact that is ONLY about the old, corrected employer, linked to `old`.
        let oldOnly = try await f.remember("OldCo is a bakery.")
        try f.store.link(MemoryEdge(fromID: old.id, toID: oldOnly.id, relation: "about-place"))

        let related = try f.store.related(to: anchor.id)

        // The only path anchor→oldOnly runs through the anchor→old *supersedes*
        // edge. A correction is not a topical relation, so a fact about the
        // corrected version must not surface as related to the current one.
        #expect(!related.contains { $0.id == oldOnly.id })
    }
}
