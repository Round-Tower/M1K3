//
//  ChatHistoryStoreTests.swift
//  M1K3ChatTests
//
//  The GRDB conversation store: blob-per-conversation (the calls idiom),
//  plaintext columns only for listing (title + timestamps). Round-trips,
//  upserts, ordering, and file-backed persistence pinned here.
//

import Foundation
@testable import M1K3Chat
import M1K3Knowledge
import Testing

private func sampleMessages() -> [ChatMessage] {
    [
        ChatMessage(role: .user, text: "what failed on the conveyor?", status: .complete),
        ChatMessage(
            role: .assistant,
            text: "The hydraulic seal failed under load.",
            sources: [ChunkHit(
                chunkID: UUID(), itemID: UUID(), itemTitle: "Plant Notes", kind: .document,
                heading: "3.2 Seals", content: "The hydraulic seal on the conveyor failed under load."
            )],
            reasoning: "The user asks about the conveyor.",
            status: .complete
        ),
        ChatMessage(role: .assistant, text: "", status: .failed("model unavailable")),
    ]
}

struct ChatHistoryStoreTests {
    @Test("save then list yields one untitled summary with the passed timestamps")
    func saveAndList() throws {
        let store = try GRDBChatHistoryStore()
        let id = UUID()
        let when = Date(timeIntervalSince1970: 1000)
        try store.save(id: id, messages: sampleMessages(), updatedAt: when)
        let summaries = try store.list()
        #expect(summaries.count == 1)
        #expect(summaries[0].id == id)
        #expect(summaries[0].title == nil)
        #expect(summaries[0].createdAt == when)
        #expect(summaries[0].updatedAt == when)
    }

    @Test("loadMessages round-trips reasoning, failed status, and sources")
    func roundTrip() throws {
        let store = try GRDBChatHistoryStore()
        let id = UUID()
        let original = sampleMessages()
        try store.save(id: id, messages: original, updatedAt: Date())
        let loaded = try store.loadMessages(id: id)
        #expect(loaded == original)
    }

    @Test("saveAsync persists identically to save (native async write path)")
    func saveAsyncRoundTrips() async throws {
        let store = try GRDBChatHistoryStore()
        let id = UUID()
        let when = Date(timeIntervalSince1970: 2000)
        let original = sampleMessages()
        try await store.saveAsync(id: id, messages: original, updatedAt: when)
        #expect(try store.loadMessages(id: id) == original)
        let summaries = try store.list()
        #expect(summaries.count == 1)
        #expect(summaries[0].id == id)
        #expect(summaries[0].updatedAt == when)
    }

    @Test("saveAsync upserts the same row as save (no duplicate, updatedAt advances)")
    func saveAsyncUpserts() async throws {
        let store = try GRDBChatHistoryStore()
        let id = UUID()
        let full = sampleMessages()
        let created = Date(timeIntervalSince1970: 100)
        try store.save(id: id, messages: [full[0]], updatedAt: created)
        let updated = Date(timeIntervalSince1970: 300)
        try await store.saveAsync(id: id, messages: full, updatedAt: updated)
        #expect(try store.list().count == 1)
        #expect(try store.loadMessages(id: id) == full)
        #expect(try store.list()[0].createdAt == created)
        #expect(try store.list()[0].updatedAt == updated)
    }

    @Test("a second save upserts: payload replaced, updatedAt advanced, createdAt preserved")
    func upsert() throws {
        let store = try GRDBChatHistoryStore()
        let id = UUID()
        let created = Date(timeIntervalSince1970: 1000)
        let updated = Date(timeIntervalSince1970: 2000)
        try store.save(id: id, messages: [sampleMessages()[0]], updatedAt: created)
        try store.save(id: id, messages: sampleMessages(), updatedAt: updated)
        let summaries = try store.list()
        #expect(summaries.count == 1)
        #expect(summaries[0].createdAt == created)
        #expect(summaries[0].updatedAt == updated)
        #expect(try store.loadMessages(id: id)?.count == 3)
    }

    @Test("list orders by updatedAt descending")
    func listOrdering() throws {
        let store = try GRDBChatHistoryStore()
        let old = UUID()
        let mid = UUID()
        let new = UUID()
        try store.save(id: old, messages: sampleMessages(), updatedAt: Date(timeIntervalSince1970: 100))
        try store.save(id: new, messages: sampleMessages(), updatedAt: Date(timeIntervalSince1970: 300))
        try store.save(id: mid, messages: sampleMessages(), updatedAt: Date(timeIntervalSince1970: 200))
        #expect(try store.list().map(\.id) == [new, mid, old])
    }

    @Test("setTitle reflects in list; unknown id creates nothing")
    func titles() throws {
        let store = try GRDBChatHistoryStore()
        let id = UUID()
        try store.save(id: id, messages: sampleMessages(), updatedAt: Date())
        try store.setTitle(id: id, title: "Conveyor seal failure")
        #expect(try store.list().first?.title == "Conveyor seal failure")
        try store.setTitle(id: UUID(), title: "ghost")
        #expect(try store.list().count == 1)
    }

    @Test("delete removes and reports; unknown id reports false")
    func deletion() throws {
        let store = try GRDBChatHistoryStore()
        let id = UUID()
        try store.save(id: id, messages: sampleMessages(), updatedAt: Date())
        #expect(try store.delete(id: id) == true)
        #expect(try store.list().isEmpty)
        #expect(try store.delete(id: UUID()) == false)
    }

    @Test("loadMessages for an unknown id is nil, not empty")
    func loadUnknown() throws {
        let store = try GRDBChatHistoryStore()
        #expect(try store.loadMessages(id: UUID()) == nil)
    }

    @Test("a title leaked from reasoning before #561 lists as untitled; the stored row is left alone")
    func reasoningLeakTitleListsUntitled() throws {
        let store = try GRDBChatHistoryStore()
        let leaked = UUID(), clean = UUID()
        try store.save(id: leaked, messages: sampleMessages(), updatedAt: Date())
        try store.save(id: clean, messages: sampleMessages(), updatedAt: Date(timeIntervalSince1970: 1))
        try store.setTitle(id: leaked, title: "<think>Thinking Process")
        try store.setTitle(id: clean, title: "Conveyor seal failure")
        let titles = try Dictionary(uniqueKeysWithValues: store.list().map { ($0.id, $0.title) })
        #expect(titles[leaked] == .some(nil))
        #expect(titles[clean] == "Conveyor seal failure")
        // The titler's next pass overwrites it like any untitled chat.
        try store.setTitle(id: leaked, title: "Weather in Cork")
        #expect(try store.list().first { $0.id == leaked }?.title == "Weather in Cork")
    }

    @Test("a file-backed store persists across instances")
    func filePersistence() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-history-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("chat-history.sqlite").path

        let id = UUID()
        do {
            let store = try GRDBChatHistoryStore(path: path)
            try store.save(id: id, messages: sampleMessages(), updatedAt: Date())
            try store.setTitle(id: id, title: "Persisted")
        }
        let reopened = try GRDBChatHistoryStore(path: path)
        #expect(try reopened.list().first?.title == "Persisted")
        #expect(try reopened.loadMessages(id: id)?.count == 3)
    }

    // MARK: - Distillation watermark

    @Test("a fresh conversation's watermark is 0")
    func freshWatermarkIsZero() throws {
        let store = try GRDBChatHistoryStore()
        let id = UUID()
        try store.save(id: id, messages: sampleMessages(), updatedAt: Date())
        #expect(try store.distilledWatermark(id: id) == 0)
    }

    @Test("the watermark round-trips")
    func watermarkRoundTrips() throws {
        let store = try GRDBChatHistoryStore()
        let id = UUID()
        try store.save(id: id, messages: sampleMessages(), updatedAt: Date())
        try store.setDistilledWatermark(id: id, count: 3)
        #expect(try store.distilledWatermark(id: id) == 3)
    }

    @Test("setting the watermark for an unknown id is a no-op (the setTitle precedent)")
    func unknownIDNoOps() throws {
        let store = try GRDBChatHistoryStore()
        try store.setDistilledWatermark(id: UUID(), count: 5)
        #expect(try store.list().isEmpty)
        // Reading an unknown id reports 0 — nothing distilled, honestly.
        #expect(try store.distilledWatermark(id: UUID()) == 0)
    }

    @Test("save's upsert does NOT reset the watermark — the no-double-distill pin")
    func saveDoesNotResetWatermark() throws {
        let store = try GRDBChatHistoryStore()
        let id = UUID()
        try store.save(id: id, messages: sampleMessages(), updatedAt: Date())
        try store.setDistilledWatermark(id: id, count: 2)
        // A later turn re-saves the conversation payload…
        try store.save(id: id, messages: sampleMessages(), updatedAt: Date().addingTimeInterval(60))
        // …and the watermark must survive, or every turn re-distills history.
        #expect(try store.distilledWatermark(id: id) == 2)
    }

    @Test("watermark persists across instances (file-backed)")
    func watermarkPersists() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m1k3-watermark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("history.sqlite").path
        let id = UUID()
        do {
            let store = try GRDBChatHistoryStore(path: path)
            try store.save(id: id, messages: sampleMessages(), updatedAt: Date())
            try store.setDistilledWatermark(id: id, count: 4)
        }
        let reopened = try GRDBChatHistoryStore(path: path)
        #expect(try reopened.distilledWatermark(id: id) == 4)
    }
}
