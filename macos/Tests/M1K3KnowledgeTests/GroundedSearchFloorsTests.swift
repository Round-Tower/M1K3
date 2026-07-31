//
//  GroundedSearchFloorsTests.swift
//  M1K3KnowledgeTests
//
//  GroundedSearch must select relevance floors from the embedder it is
//  handed — the per-embedder seam. A hashing-cone memory hit (token-overlap
//  cosine ~0.25) is a REAL recall for the hashing embedder but sub-floor
//  noise in the qwen cone; the shared bar silently dropped it on iOS, where
//  hashing is the only embedder.
//
//  Signed: Kev + claude-fable-5, 2026-07-31, Confidence 0.85, Prior: Unknown
//

import Foundation
@testable import M1K3Knowledge
import Testing

struct GroundedSearchFloorsTests {
    /// One shared content token in four query tokens → hashing cosine ≈ 0.25
    /// (engineered overlap; verified in-test rather than assumed, because FNV
    /// bucket collisions could shift it).
    private static let memoryText = "bran collie dog kev"
    private static let query = "bran zeta eta theta"

    private func makeStore(embedder: HashingEmbeddingService) async throws -> KnowledgeStore {
        let store = try KnowledgeStore()
        let memID = UUID()
        let item = KnowledgeItem(id: memID, kind: .memory, title: Self.memoryText, sourceRef: "sha:mem")
        let chunk = KnowledgeChunk(itemID: memID, ordinal: 0, content: Self.memoryText)
        try await store.index(
            item: item, chunks: [chunk],
            embeddings: embedder.embedBatch([Self.memoryText])
        )
        return store
    }

    @Test("a hashing-cone memory recall survives GroundedSearch under the hashing embedder")
    func hashingEmbedderRecalls() async throws {
        let embedder = HashingEmbeddingService()
        let store = try await makeStore(embedder: embedder)

        // Prove the fixture sits in the divergence band [0.10, 0.35).
        let sim = try await VectorMath.cosineSimilarity(
            embedder.embedQuery(Self.query), embedder.embed(Self.memoryText)
        )
        #expect(sim >= EmbedderFloors.hashing.memory)
        #expect(sim < EmbedderFloors.qwen3Instructed.memory)

        let hits = try await GroundedSearch.run(
            store: store, embedder: embedder, query: Self.query, limit: 5
        )
        #expect(hits.contains { $0.kind == .memory && $0.content == Self.memoryText })
    }
}
