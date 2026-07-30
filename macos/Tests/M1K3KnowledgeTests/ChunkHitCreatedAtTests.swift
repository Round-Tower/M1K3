//
//  ChunkHitCreatedAtTests.swift
//  M1K3KnowledgeTests
//
//  Tier 1 (scratch/dream-cycle/SPEC.md): search hits carry the item's
//  created_at so the memory block can render honest recency. Pins BOTH
//  retrieval lanes (FTS + vector) and the maintenance path: a reindex
//  rewrites vectors only — if it ever touched created_at, every memory
//  would read "learned today" after maintenance and the recency signal
//  would be a lie.
//
//  Signed: Kev + claude-fable-5, 2026-07-30, Confidence 0.9. Prior: Unknown
//

import Foundation
@testable import M1K3Knowledge
import Testing

struct ChunkHitCreatedAtTests {
    private let embedder = HashingEmbeddingService()
    private let seeded = Date(timeIntervalSince1970: 1_700_000_000)
    private let fact = "Kev lives in Ardmore."

    private func seededStore() async throws -> KnowledgeStore {
        let store = try KnowledgeStore()
        let item = KnowledgeItem(kind: .memory, title: fact, createdAt: seeded)
        let chunk = KnowledgeChunk(itemID: item.id, ordinal: 0, heading: nil, content: fact)
        let vector = try await embedder.embed(EmbeddingText.forChunk(title: fact, content: fact))
        try store.index(item: item, chunks: [chunk], embeddings: [vector])
        return store
    }

    @Test("FTS hits carry the item's createdAt")
    func ftsLane() async throws {
        let store = try await seededStore()

        let hits = try store.searchFTS(query: "Ardmore", kinds: [.memory])

        let hit = try #require(hits.first)
        let created = try #require(hit.createdAt)
        #expect(abs(created.timeIntervalSince(seeded)) < 1)
    }

    @Test("vector hits carry the item's createdAt")
    func vectorLane() async throws {
        let store = try await seededStore()

        let hits = try store.searchVector(
            queryVector: await embedder.embed(fact), kinds: [.memory]
        )

        let hit = try #require(hits.first)
        let created = try #require(hit.createdAt)
        #expect(abs(created.timeIntervalSince(seeded)) < 1)
    }

    @Test("reindexEmbeddings preserves createdAt — recency survives maintenance")
    func reindexPreservesCreatedAt() async throws {
        let store = try await seededStore()

        _ = try await store.reindexEmbeddings(using: embedder, fingerprint: "re-test")

        let hits = try store.searchFTS(query: "Ardmore", kinds: [.memory])
        let hit = try #require(hits.first)
        let created = try #require(hit.createdAt)
        #expect(abs(created.timeIntervalSince(seeded)) < 1)
    }
}
