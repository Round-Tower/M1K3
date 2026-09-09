//
//  DemoSeederTests.swift
//  M1K3ScreengrabTests
//
//  Drives the seeder against the REAL stores on a temp directory: the hero
//  conversation is the most recent (so ChatSession's resume-most-recent finds
//  it), the memories and documents land, and a second seed is a no-op — the
//  suite launches the app once per plate.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-07, Confidence 0.85, Prior: Unknown
//

import Foundation
import M1K3Chat
import M1K3Knowledge
import M1K3Memory
@testable import M1K3Screengrab
import Testing

struct DemoSeederTests {
    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("screengrab-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func historySeedIsTheMostRecentConversationAndIdempotent() throws {
        let root = try tempRoot()
        let history = try GRDBChatHistoryStore(path: root.appendingPathComponent("chat-history.sqlite").path)
        try DemoSeeder.seedHistory(into: history, root: root)
        try DemoSeeder.seedHistory(into: history, root: root)
        let list = try history.list()
        #expect(list.count == 1)
        #expect(list.first?.title == DemoPersona.heroTitle)
        let messages = try history.loadMessages(id: list[0].id)
        #expect(messages?.map(\.text) == DemoPersona.heroConversation.map(\.text))
        #expect(messages?.allSatisfy { $0.status == .complete } == true)
        #expect(try history.distilledWatermark(id: list[0].id) == DemoPersona.heroConversation.count)
    }

    @Test func knowledgeSeedLandsMemoriesAndDocumentsOnce() async throws {
        let root = try tempRoot()
        let store = try KnowledgeStore(path: root.appendingPathComponent("knowledge.sqlite").path)
        let memory = try MemoryStore(path: root.appendingPathComponent("memory.sqlite").path)
        let embedder = HashingEmbeddingService()
        let ingester = DocumentIngester(store: store, embedder: embedder)
        try await DemoSeeder.seedKnowledge(memory: memory, ingester: ingester, embedder: embedder, root: root)
        try await DemoSeeder.seedKnowledge(memory: memory, ingester: ingester, embedder: embedder, root: root)
        #expect(try memory.liveCount() == DemoPersona.memories.count)
        #expect(try store.allItems(kind: .document).count == DemoPersona.documents.count)
        let vector = try await embedder.embed("lair")
        let hits = try memory.recall(query: "lair", queryVector: vector, limit: 3, threshold: 0)
        #expect(!hits.isEmpty)
    }

    /// A kill between the row and the marker must not seed a second hero conversation.
    @Test func historySeedSurvivesMarkerLoss() throws {
        let root = try tempRoot()
        let history = try GRDBChatHistoryStore(path: root.appendingPathComponent("chat-history.sqlite").path)
        try DemoSeeder.seedHistory(into: history, root: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent(".demo-history-seeded"))
        try DemoSeeder.seedHistory(into: history, root: root)
        #expect(try history.list().count == 1)
    }

    @Test func knowledgeSeedSurvivesMarkerLoss() async throws {
        let root = try tempRoot()
        let store = try KnowledgeStore(path: root.appendingPathComponent("knowledge.sqlite").path)
        let memory = try MemoryStore(path: root.appendingPathComponent("memory.sqlite").path)
        let embedder = HashingEmbeddingService()
        let ingester = DocumentIngester(store: store, embedder: embedder)
        try await DemoSeeder.seedKnowledge(memory: memory, ingester: ingester, embedder: embedder, root: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent(".demo-knowledge-seeded"))
        try await DemoSeeder.seedKnowledge(memory: memory, ingester: ingester, embedder: embedder, root: root)
        #expect(try memory.liveCount() == DemoPersona.memories.count)
        #expect(try store.allItems(kind: .document).count == DemoPersona.documents.count)
    }
}
