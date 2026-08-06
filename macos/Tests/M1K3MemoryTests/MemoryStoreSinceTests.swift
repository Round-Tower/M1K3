//
//  MemoryStoreSinceTests.swift
//  M1K3MemoryTests
//
//  Pins the heartbeat's time-window read: live memories created at or after
//  a watermark, filtered IN SQL on the indexed column — never fetch-then-
//  partition in Swift (the PR #94 lesson: a shared row budget silently
//  truncates), and never a superseded row (a corrected fact isn't news).
//
//  Signed: Kev + claude-fable-5, 2026-08-06, Confidence 0.9 (pinned
//  red-first against the in-memory store). Prior: none (new file).
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
        _ text: String,
        at date: Date,
        supersedes oldID: UUID? = nil
    ) async throws -> Memory {
        let memory = Memory(kind: .note, text: text, source: "test", createdAt: date)
        try store.remember(memory, embedding: await embedder.embed(text), supersedes: oldID)
        return memory
    }
}

struct MemoryStoreSinceTests {
    private let base = Date(timeIntervalSince1970: 1_754_480_000)

    @Test("memoriesCreated(since:) returns only rows at or after the watermark")
    func windowFilter() async throws {
        let f = try Fixture()
        try await f.remember("old fact", at: base.addingTimeInterval(-7200))
        let fresh = try await f.remember("fresh fact", at: base.addingTimeInterval(60))

        let window = try f.store.memoriesCreated(since: base)

        #expect(window.map(\.id) == [fresh.id])
    }

    @Test("superseded rows are excluded — a corrected fact isn't news")
    func supersededExcluded() async throws {
        let f = try Fixture()
        let stale = try await f.remember("Kev lives in Dublin", at: base.addingTimeInterval(10))
        try await f.remember("Kev lives in Ardmore", at: base.addingTimeInterval(20), supersedes: stale.id)

        let window = try f.store.memoriesCreated(since: base)

        #expect(window.map(\.text) == ["Kev lives in Ardmore"])
    }

    @Test("newest first, capped by limit")
    func orderingAndLimit() async throws {
        let f = try Fixture()
        for index in 0 ..< 5 {
            try await f.remember("fact \(index)", at: base.addingTimeInterval(Double(index)))
        }

        let window = try f.store.memoriesCreated(since: base, limit: 3)

        #expect(window.map(\.text) == ["fact 4", "fact 3", "fact 2"])
    }
}
