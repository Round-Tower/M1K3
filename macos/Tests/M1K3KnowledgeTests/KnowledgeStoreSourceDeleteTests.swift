//
//  KnowledgeStoreSourceDeleteTests.swift
//  M1K3KnowledgeTests
//
//  #711: an import tags every corpus row it writes (`KnowledgeItem.source`), so the corpus half of
//  "forget everything from this import" is a lookup by source and the per-item hard delete.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85 (in-memory GRDB + the hashing
//  embedder; the cascade is deleteItem's).
//  Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-27 (pre-push review fold) — `kinds:` pinned (empty set, a hidden kind matched
//  by name, a multi-kind list), positive controls before the delete, and the new bulk `deleteItems(ids:)` and
//  `deleteMeta(keys:)`. The FTS check reads through the item join, so the title no longer claims FTS rows.
//  Confidence 0.85.

import Foundation
@testable import M1K3Knowledge
import Testing

private let tag = KnowledgeSource(rawValue: "import/claude/2026-10-26")

struct KnowledgeStoreSourceDeleteTests {
    private func seeded() async throws -> (KnowledgeStore, imported: Set<UUID>) {
        let store = try KnowledgeStore()
        let ingester = DocumentIngester(store: store, embedder: HashingEmbeddingService())
        let fact = try await ingester.ingest(
            title: "Kev keeps bees", text: "Kev keeps bees in Kinsale", kind: .memory, source: tag
        )
        let chat = try await ingester.ingest(
            title: "Planning the hives", text: "User: where should the hives face? Assistant: south-east.",
            kind: .conversation, source: tag
        )
        try await ingester.ingest(
            title: "Kev drinks tea", text: "Kev drinks tea", kind: .memory, source: .distilled
        )
        try await ingester.ingest(title: "Manual", text: "The torque setting is forty newton metres")
        return (store, [fact.itemID, chat.itemID])
    }

    @Test("itemIDs(source:) lists exactly the tagged items; kinds narrows it")
    func listsOnlyThatSource() async throws {
        let (store, imported) = try await seeded()
        #expect(try Set(store.itemIDs(source: tag)) == imported)
        #expect(try store.itemIDs(source: tag, kinds: [.conversation]).count == 1)
        #expect(try store.itemIDs(source: KnowledgeSource(rawValue: "import/chatgpt/2026-10-26")).isEmpty)
        #expect(try store.itemIDs(source: tag, kinds: []).isEmpty)
        #expect(try Set(store.itemIDs(source: tag, kinds: [.memory, .conversation])) == imported)

        // A kind hidden from retrieval is still matched when named: forget's inventory, not a search.
        let fact = try #require(try store.itemIDs(source: tag, kinds: [.memory]).first)
        #expect(try store.setKind(id: fact, newKind: .memorySuperseded))
        #expect(try store.itemIDs(source: tag, kinds: [.memorySuperseded]) == [fact])
        #expect(try store.itemIDs(source: tag, kinds: [.memory]).isEmpty)
        #expect(try Set(store.itemIDs(source: tag)) == imported)
    }

    @Test("deleteItems(source:) removes the items, their chunks and vectors, and nothing else")
    func itemsBySourceCascade() async throws {
        let (store, _) = try await seeded()
        #expect(try store.itemCount() == 4)
        #expect(try !store.searchFTS(query: "hives").isEmpty)
        #expect(try !store.searchFTS(query: "Kinsale").isEmpty)

        let removed = try store.deleteItems(source: tag)

        #expect(removed == 2)
        #expect(try store.itemCount() == 2)
        #expect(try store.chunkCount() == 2)
        #expect(try store.embeddingCount() == 2)
        #expect(try store.searchFTS(query: "hives").isEmpty)
        #expect(try store.searchFTS(query: "Kinsale").isEmpty)
        #expect(try !store.searchFTS(query: "torque").isEmpty)
        #expect(try store.allItems(kind: .memory).map(\.source) == [.distilled])
        #expect(try store.deleteItems(source: tag) == 0)
    }

    @Test("deleteItems(ids:) removes exactly those items in one call; deleteMeta(keys:) exactly those keys")
    func bulkDeletes() async throws {
        let (store, imported) = try await seeded()
        try store.setMeta(key: "a", value: "1")
        try store.setMeta(key: "b", value: "2")
        try store.setMeta(key: "c", value: "3")

        #expect(try store.deleteItems(ids: Array(imported) + [UUID()]) == 2)
        #expect(try store.deleteItems(ids: []) == 0)
        try store.deleteMeta(keys: ["a", "c", "missing"])
        try store.deleteMeta(keys: [])

        #expect(try store.itemCount() == 2)
        #expect(try store.chunkCount() == 2)
        #expect(try store.embeddingCount() == 2)
        #expect(try store.meta(key: "a") == nil)
        #expect(try store.meta(key: "b") == "2")
        #expect(try store.meta(key: "c") == nil)
    }
}
