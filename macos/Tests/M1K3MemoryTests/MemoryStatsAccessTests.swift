//
//  MemoryStatsAccessTests.swift
//  M1K3MemoryTests
//
//  The two read APIs the Tier-0 MEMSTAT census needs from the store: live
//  embedding vectors (superseded excluded — a superseded row's vector would
//  poison the pairwise histogram with pairs retrieval can never see) and live
//  per-kind counts.
//
//  Signed: Kev + claude-fable-5, 2026-07-30, Confidence 0.9. Prior: Unknown
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
        kind: MemoryKind = .note,
        supersedes oldID: UUID? = nil
    ) async throws -> Memory {
        let memory = Memory(kind: kind, text: text, source: "test")
        try store.remember(memory, embedding: await embedder.embed(text), supersedes: oldID)
        return memory
    }
}

struct MemoryStatsAccessTests {
    @Test("liveEmbeddingVectors returns one vector per live memory")
    func liveVectors() async throws {
        let f = try Fixture()
        try await f.remember("Kev lives in Ardmore", kind: .profile)
        try await f.remember("Kev prefers metric units", kind: .preference)

        let vectors = try f.store.liveEmbeddingVectors()

        #expect(vectors.count == 2)
        #expect(vectors.allSatisfy { !$0.isEmpty })
    }

    @Test("superseded rows are excluded from the census vectors")
    func supersededExcluded() async throws {
        let f = try Fixture()
        let old = try await f.remember("Kev lives in Dublin", kind: .profile)
        try await f.remember("Kev lives in Ardmore", kind: .profile, supersedes: old.id)

        let vectors = try f.store.liveEmbeddingVectors()

        #expect(vectors.count == 1)
    }

    @Test("liveCountsByKind counts live rows per kind, superseded excluded")
    func countsByKind() async throws {
        let f = try Fixture()
        try await f.remember("fact one", kind: .profile)
        try await f.remember("fact two", kind: .note)
        try await f.remember("fact three", kind: .note)
        let old = try await f.remember("stale", kind: .preference)
        try await f.remember("fresh", kind: .preference, supersedes: old.id)

        let counts = try f.store.liveCountsByKind()

        #expect(counts[MemoryKind.profile.rawValue] == 1)
        #expect(counts[MemoryKind.note.rawValue] == 2)
        #expect(counts[MemoryKind.preference.rawValue] == 1)
    }

    @Test("totalCount counts every row including superseded, without hydration")
    func totalCount() async throws {
        let f = try Fixture()
        let old = try await f.remember("Kev lives in Dublin", kind: .profile)
        try await f.remember("Kev lives in Ardmore", kind: .profile, supersedes: old.id)

        #expect(try f.store.totalCount() == 2)
        #expect(try f.store.liveCount() == 1)
    }

    @Test("empty store yields empty census")
    func emptyStore() throws {
        let f = try Fixture()
        #expect(try f.store.liveEmbeddingVectors().isEmpty)
        #expect(try f.store.liveCountsByKind().isEmpty)
    }
}
