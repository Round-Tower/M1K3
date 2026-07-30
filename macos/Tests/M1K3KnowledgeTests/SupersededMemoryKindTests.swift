//
//  SupersededMemoryKindTests.swift
//  M1K3KnowledgeTests
//
//  Tier 2 (scratch/dream-cycle/SPEC.md): the corpus twin of a superseded
//  memory is re-kinded to `.memorySuperseded` — same exclusion semantics as
//  `.quarantined` (invisible to every retrieval surface unless named), but a
//  DISTINCT kind so restore rules can't collide with operator-QA quarantine
//  (Security M1). Restoration is a plain setKind back to `.memory`.
//
//  Signed: Kev + claude-fable-5, 2026-07-30, Confidence 0.9. Prior:
//  quarantine index-segregation tests (PR #28 era).
//

import Foundation
@testable import M1K3Knowledge
import Testing

struct SupersededMemoryKindTests {
    private let embedder = HashingEmbeddingService()

    private func store(withSuperseded fact: String) async throws -> (KnowledgeStore, UUID) {
        let store = try KnowledgeStore()
        let item = KnowledgeItem(kind: .memorySuperseded, title: fact, sourceRef: "t2:\(fact)")
        let chunk = KnowledgeChunk(itemID: item.id, ordinal: 0, heading: nil, content: fact)
        let vector = try await embedder.embed(EmbeddingText.forChunk(title: fact, content: fact))
        try store.index(item: item, chunks: [chunk], embeddings: [vector])
        return (store, item.id)
    }

    @Test("superseded-memory items are invisible to FTS with nil kinds")
    func ftsDefaultDeny() async throws {
        let (store, _) = try await store(withSuperseded: "Kev lives in Dublin.")
        #expect(try store.searchFTS(query: "Dublin").isEmpty)
    }

    @Test("superseded-memory items are invisible to vector search with nil kinds")
    func vectorDefaultDeny() async throws {
        let (store, _) = try await store(withSuperseded: "Kev lives in Dublin.")
        let hits = try store.searchVector(
            queryVector: await embedder.embed("Kev lives in Dublin.")
        )
        #expect(hits.isEmpty)
    }

    @Test("superseded-memory items are excluded from the default listing")
    func listingDefaultDeny() async throws {
        let (store, _) = try await store(withSuperseded: "Kev lives in Dublin.")
        #expect(try store.allItems().isEmpty)
    }

    @Test("naming the kind reaches superseded items — restore stays possible")
    func reachableByName() async throws {
        let (store, id) = try await store(withSuperseded: "Kev lives in Dublin.")
        #expect(try store.allItems(kind: .memorySuperseded).count == 1)
        #expect(try store.searchFTS(query: "Dublin", kinds: [.memorySuperseded]).count == 1)

        // Restore = setKind back to .memory → retrieval sees it again.
        #expect(try store.setKind(id: id, newKind: .memory))
        #expect(try store.searchFTS(query: "Dublin").count == 1)
    }

    @Test("quarantined and memorySuperseded are distinct kinds")
    func distinctFromQuarantine() {
        #expect(KnowledgeKind.memorySuperseded != KnowledgeKind.quarantined)
        #expect(KnowledgeKind.hiddenFromRetrieval.contains(.memorySuperseded))
        #expect(KnowledgeKind.hiddenFromRetrieval.contains(.quarantined))
    }
}
