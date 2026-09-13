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
//  Review: Kev + claude-opus-5, 2026-09-13 — pins the every-launch hero restore (a voice turn
//  grew the demo conversation run over run). Confidence 0.9.
//

import Foundation
import M1K3Chat
import M1K3Knowledge
import M1K3Memory
@testable import M1K3Screengrab
import Testing

struct DemoSeederTests {
    private func tempRoot() throws -> URL {
        // Shaped like the real sibling root: the seeder prunes only there.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("screengrab-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(ScreengrabHarness.dataRootName, isDirectory: true)
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

    /// Every launch restores the hero conversation: a previous run's voice turn
    /// appended its question and answer to it, and the NEXT run's chat plate
    /// showed the exchange three times (2026-09-13 capture). The demo root is
    /// disposable, so a stray conversation is dropped too — the chat plate
    /// resumes the most recent one.
    @Test func historySeedRestoresTheHeroConversationEveryLaunch() throws {
        let root = try tempRoot()
        let history = try GRDBChatHistoryStore(path: root.appendingPathComponent("chat-history.sqlite").path)
        try DemoSeeder.seedHistory(into: history, root: root)
        let heroID = try #require(try history.list().first?.id)
        let grown = try #require(try history.loadMessages(id: heroID)) + DemoPersona.heroConversation
        try history.save(id: heroID, messages: grown, updatedAt: Date())
        try history.save(id: UUID(), messages: DemoPersona.heroConversation, updatedAt: Date().addingTimeInterval(60))

        try DemoSeeder.seedHistory(into: history, root: root)

        let list = try history.list()
        #expect(list.count == 1)
        #expect(list.first?.title == DemoPersona.heroTitle)
        let messages = try history.loadMessages(id: list[0].id)
        #expect(messages?.map(\.text) == DemoPersona.heroConversation.map(\.text))
        #expect(try history.distilledWatermark(id: list[0].id) == DemoPersona.heroConversation.count)
    }

    /// The prune is scoped to the screengrab root: any other store keeps
    /// every conversation it had, even if a seed is ever pointed at it.
    @Test func historySeedNeverPrunesOutsideTheScreengrabRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let history = try GRDBChatHistoryStore(path: root.appendingPathComponent("chat-history.sqlite").path)
        let mine = UUID()
        try history.save(id: mine, messages: DemoPersona.heroConversation, updatedAt: Date())
        try DemoSeeder.seedHistory(into: history, root: root)
        #expect(try history.loadMessages(id: mine) != nil)
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
