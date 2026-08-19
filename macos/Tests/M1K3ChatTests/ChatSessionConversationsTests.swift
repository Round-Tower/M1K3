//
//  ChatSessionConversationsTests.swift
//  M1K3ChatTests
//
//  Multi-conversation behaviour of ChatSession: resume-most-recent, lazy row
//  creation (empty conversations never persist), switch/new/delete with their
//  isResponding guards, and the fire-and-forget auto-titling hook with its
//  switch race. All against an in-memory store + fake responders/titlers.
//

import Foundation
@testable import M1K3Chat
import M1K3Inference
import M1K3Knowledge
import Testing

// MARK: - Fakes

private final class InMemoryHistoryStore: ChatHistoryPersisting, @unchecked Sendable {
    private var feedbackRows: [UUID: AnswerFeedback] = [:]
    private struct Row {
        var title: String?
        var createdAt: Date
        var updatedAt: Date
        var messages: [ChatMessage]
    }

    private let lock = NSLock()
    private var rows: [UUID: Row] = [:]
    private(set) var setTitleCalls: [(UUID, String)] = []
    /// Records whether the most recent `save` ran on the main thread — the
    /// probe for finding 25/30 (the per-turn transcript encode+write must move
    /// off the MainActor). nil until the first save.
    private var _lastSaveOnMainThread: Bool?
    var lastSaveOnMainThread: Bool? {
        lock.withLock { _lastSaveOnMainThread }
    }

    func list() throws -> [ConversationSummary] {
        lock.lock()
        defer { lock.unlock() }
        return rows
            .map { ConversationSummary(id: $0.key, title: $0.value.title, createdAt: $0.value.createdAt, updatedAt: $0.value.updatedAt) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func loadMessages(id: UUID) throws -> [ChatMessage]? {
        lock.lock()
        defer { lock.unlock() }
        return rows[id]?.messages
    }

    func save(id: UUID, messages: [ChatMessage], updatedAt: Date) throws {
        lock.lock()
        defer { lock.unlock() }
        _lastSaveOnMainThread = Thread.isMainThread
        if var row = rows[id] {
            row.messages = messages
            row.updatedAt = updatedAt
            rows[id] = row
        } else {
            rows[id] = Row(title: nil, createdAt: updatedAt, updatedAt: updatedAt, messages: messages)
        }
    }

    func setTitle(id: UUID, title: String) throws {
        lock.lock()
        defer { lock.unlock() }
        setTitleCalls.append((id, title))
        guard var row = rows[id] else { return }
        row.title = title
        rows[id] = row
    }

    /// Simulate a DB write failure (the GRDB store's delete runs in
    /// dbQueue.write and can throw) — the attachment-discard gate probe.
    var failsDeletes = false

    @discardableResult
    func delete(id: UUID) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if failsDeletes { throw CocoaError(.fileWriteUnknown) }
        return rows.removeValue(forKey: id) != nil
    }

    private var watermarks: [UUID: Int] = [:]

    func distilledWatermark(id: UUID) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        return watermarks[id] ?? 0
    }

    func setDistilledWatermark(id: UUID, count: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        guard rows[id] != nil else { return }
        watermarks[id] = count
    }

    func recordFeedback(_ feedback: AnswerFeedback) throws {
        lock.lock(); defer { lock.unlock() }
        feedbackRows[feedback.messageID] = feedback
    }

    func feedbackVerdicts(conversationID: UUID) throws -> [UUID: FeedbackVerdict] {
        lock.lock(); defer { lock.unlock() }
        return feedbackRows.values
            .filter { $0.conversationID == conversationID }
            .reduce(into: [:]) { $0[$1.messageID] = $1.verdict }
    }

    func allFeedback() throws -> [AnswerFeedback] {
        lock.lock(); defer { lock.unlock() }
        return feedbackRows.values.sorted { $0.createdAt > $1.createdAt }
    }

    /// Test seeding helper.
    func seed(id: UUID, title: String?, updatedAt: Date, messages: [ChatMessage]) {
        lock.lock()
        defer { lock.unlock() }
        rows[id] = Row(title: title, createdAt: updatedAt, updatedAt: updatedAt, messages: messages)
    }
}

private struct EchoResponder: RAGResponding {
    func answerStreaming(_ question: String) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        let stream = AsyncStream<String> { continuation in
            continuation.yield("echo: \(question)")
            continuation.finish()
        }
        return ([], stream)
    }
}

private struct ThrowingResponder: RAGResponding {
    struct Boom: Error {}
    func answerStreaming(_: String) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        throw Boom()
    }
}

/// Holds the stream open until the test releases it — for isResponding guards.
private final class GatedResponder: RAGResponding, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<String>.Continuation?

    func answerStreaming(_: String) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        let stream = AsyncStream<String> { continuation in
            self.lock.lock()
            self.continuation = continuation
            self.lock.unlock()
            continuation.yield("partial")
        }
        return ([], stream)
    }

    func release() {
        lock.lock()
        let held = continuation
        continuation = nil
        lock.unlock()
        held?.finish()
    }
}

private final class FakeTitler: ConversationTitling, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [(user: String, assistant: String)] = []
    var result: String
    var shouldThrow = false

    init(result: String = "Canned Title") {
        self.result = result
    }

    func title(forUser user: String, assistant: String) async throws -> String {
        // NSLock.lock() is unavailable in async contexts — record via a
        // synchronous helper instead.
        let (throwing, canned) = record(user: user, assistant: assistant)
        if throwing { throw ThrowingResponder.Boom() }
        return canned
    }

    private func record(user: String, assistant: String) -> (Bool, String) {
        lock.lock()
        defer { lock.unlock() }
        calls.append((user, assistant))
        return (shouldThrow, result)
    }
}

private func completedMessages(_ pairs: [(String, String)]) -> [ChatMessage] {
    pairs.flatMap { user, assistant in
        [
            ChatMessage(role: .user, text: user, status: .complete),
            ChatMessage(role: .assistant, text: assistant, status: .complete),
        ]
    }
}

// MARK: - Lifecycle

@MainActor
struct ChatSessionConversationsTests {
    @Test("a fresh session with an empty store creates no row and lists nothing")
    func freshSessionIsLazy() throws {
        let store = InMemoryHistoryStore()
        let session = ChatSession(responder: EchoResponder(), history: store)
        #expect(session.messages.isEmpty)
        #expect(session.conversationSummaries().isEmpty)
        #expect(try store.list().isEmpty)
    }

    @Test("a seeded store resumes the most recent conversation")
    func resumesMostRecent() {
        let store = InMemoryHistoryStore()
        let older = UUID()
        let newer = UUID()
        store.seed(id: older, title: "Old chat", updatedAt: Date(timeIntervalSince1970: 100),
                   messages: completedMessages([("a", "b")]))
        store.seed(id: newer, title: "New chat title", updatedAt: Date(timeIntervalSince1970: 200),
                   messages: completedMessages([("c", "d"), ("e", "f")]))
        let session = ChatSession(responder: EchoResponder(), history: store)
        #expect(session.activeConversationID == newer)
        #expect(session.activeTitle == "New chat title")
        #expect(session.messages.count == 4)
    }

    @Test("send persists the active conversation and bumps historyRevision")
    func sendPersists() async throws {
        let store = InMemoryHistoryStore()
        let session = ChatSession(responder: EchoResponder(), history: store)
        let revisionBefore = session.historyRevision
        await session.send("hello")
        #expect(try store.loadMessages(id: session.activeConversationID) == session.messages)
        #expect(session.historyRevision > revisionBefore)
        #expect(try store.list().count == 1)
    }

    @Test("the per-turn transcript encode+write runs OFF the main actor (finding 25/30)")
    func persistRunsOffMainActor() async {
        let store = InMemoryHistoryStore()
        let session = ChatSession(responder: EchoResponder(), history: store)
        await session.send("hello")
        // persistActiveConversation is @MainActor, but the O(conversation) JSON
        // encode + SQLite write it drives must not run ON the main thread — that
        // was the per-turn hitch at answer completion. Awaited inline, so the row
        // is still present the instant send returns (sendPersists pins that).
        #expect(store.lastSaveOnMainThread == false)
    }

    @Test("a failed send still persists the failed message")
    func failedSendPersists() async throws {
        let store = InMemoryHistoryStore()
        let session = ChatSession(responder: ThrowingResponder(), history: store)
        await session.send("hello")
        let persisted = try #require(try store.loadMessages(id: session.activeConversationID))
        #expect(persisted.count == 2)
        if case .failed = persisted[1].status {} else { Issue.record("expected .failed status") }
    }

    @Test("startNewConversation archives the current one and starts clean")
    func newConversation() async {
        let store = InMemoryHistoryStore()
        let session = ChatSession(responder: EchoResponder(), history: store)
        await session.send("hello")
        let firstID = session.activeConversationID

        session.startNewConversation()

        #expect(session.activeConversationID != firstID)
        #expect(session.messages.isEmpty)
        #expect(session.activeTitle == nil)
        #expect(session.conversationSummaries().map(\.id) == [firstID])
    }

    @Test("startNewConversation on an empty transcript is a no-op")
    func newConversationEmptyNoOp() {
        let session = ChatSession(responder: EchoResponder(), history: InMemoryHistoryStore())
        let id = session.activeConversationID
        session.startNewConversation()
        #expect(session.activeConversationID == id)
    }

    @Test("switchTo loads the target's messages and title")
    func switching() async {
        let store = InMemoryHistoryStore()
        let session = ChatSession(responder: EchoResponder(), history: store)
        await session.send("hello")
        // Seed AFTER construction — a pre-init seed would be restored as the
        // active conversation and the switch would be a no-op.
        let other = UUID()
        store.seed(id: other, title: "Seal failure", updatedAt: Date(timeIntervalSince1970: 50),
                   messages: completedMessages([("what failed?", "the seal")]))

        session.switchTo(other)

        #expect(session.activeConversationID == other)
        #expect(session.activeTitle == "Seal failure")
        #expect(session.messages.map(\.text).contains("the seal"))
    }

    @Test("switchTo and friends are no-ops while responding")
    func guardsWhileResponding() async {
        let store = InMemoryHistoryStore()
        let gate = GatedResponder()
        let session = ChatSession(responder: gate, history: store)
        let other = UUID() // seeded post-init so it is NOT the restored-active one
        store.seed(id: other, title: nil, updatedAt: Date(timeIntervalSince1970: 50),
                   messages: completedMessages([("a", "b")]))
        let sendTask = Task { await session.send("hello") }
        // Wait until the turn is in flight.
        while !session.isResponding {
            await Task.yield()
        }
        let liveID = session.activeConversationID

        session.switchTo(other)
        session.startNewConversation()
        session.deleteConversation(other)

        #expect(session.activeConversationID == liveID)
        #expect(session.conversationSummaries().contains { $0.id == other })

        gate.release()
        await sendTask.value
    }

    @Test("switchTo an unknown id is a no-op")
    func switchUnknown() async {
        let session = ChatSession(responder: EchoResponder(), history: InMemoryHistoryStore())
        await session.send("hello")
        let id = session.activeConversationID
        session.switchTo(UUID())
        #expect(session.activeConversationID == id)
    }

    @Test("deleting a non-active conversation leaves the active one untouched")
    func deleteNonActive() async {
        let store = InMemoryHistoryStore()
        let session = ChatSession(responder: EchoResponder(), history: store)
        await session.send("hello")
        let liveID = session.activeConversationID
        let other = UUID() // seeded post-init so it is NOT the restored-active one
        store.seed(id: other, title: nil, updatedAt: Date(timeIntervalSince1970: 50),
                   messages: completedMessages([("a", "b")]))

        session.deleteConversation(other)

        #expect(session.activeConversationID == liveID)
        #expect(!session.messages.isEmpty)
        #expect(session.conversationSummaries().map(\.id) == [liveID])
    }

    @Test("deleting a conversation deletes its attachment files — a removed photo is GONE from disk")
    func deleteRemovesAttachmentFiles() async throws {
        // Privacy stance: delete the conversation, and any sensitive photo it
        // carried leaves the container too (PR #62 round-2 review fold).
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("attach-delete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("secret.png")
        try Data([0x89]).write(to: file)

        let store = InMemoryHistoryStore()
        let session = ChatSession(responder: EchoResponder(), history: store)
        await session.send("hello")
        let other = UUID()
        var seeded = completedMessages([("look at this", "nice photo")])
        seeded[0].attachments = [ImageAttachment(url: file)]
        store.seed(id: other, title: nil, updatedAt: Date(timeIntervalSince1970: 50),
                   messages: seeded)

        session.deleteConversation(other)

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(session.conversationSummaries().map(\.id) == [session.activeConversationID])
    }

    @Test("a FAILED row delete keeps the attachment files — never photo-gone-but-row-listed")
    func failedDeleteKeepsAttachmentFiles() async throws {
        // The inverse privacy failure (round-3 review): if the DB delete
        // throws, the conversation stays in the drawer — its thumbnails must
        // not be broken by an eager file discard.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("attach-failed-delete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("secret.png")
        try Data([0x89]).write(to: file)

        let store = InMemoryHistoryStore()
        let session = ChatSession(responder: EchoResponder(), history: store)
        await session.send("hello")
        let other = UUID()
        var seeded = completedMessages([("look", "photo")])
        seeded[0].attachments = [ImageAttachment(url: file)]
        store.seed(id: other, title: nil, updatedAt: Date(timeIntervalSince1970: 50),
                   messages: seeded)
        store.failsDeletes = true

        session.deleteConversation(other)

        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(session.conversationSummaries().contains { $0.id == other })
    }

    @Test("ACTIVE-conversation delete sweeps the files even when the row delete fails — the deliberate asymmetry")
    func activeDeleteSweepsFilesEvenIfRowDeleteFails() throws {
        // The inverse of failedDeleteKeepsAttachmentFiles: for the ACTIVE
        // conversation the in-memory transcript resets regardless, so the
        // photo being GONE wins over drawer-thumbnail integrity. Pinned so a
        // future "fix" of the asymmetry fails here and reads the rationale.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("attach-active-delete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("secret.png")
        try Data([0x89]).write(to: file)

        let store = InMemoryHistoryStore()
        // Seeded PRE-init → restored as the ACTIVE conversation (the fixture
        // convention: post-init seeds are the non-active ones).
        let active = UUID()
        var seeded = completedMessages([("look at this", "nice photo")])
        seeded[0].attachments = [ImageAttachment(url: file)]
        store.seed(id: active, title: nil, updatedAt: Date(timeIntervalSince1970: 100),
                   messages: seeded)
        let session = ChatSession(responder: EchoResponder(), history: store)
        #expect(session.activeConversationID == active)
        store.failsDeletes = true

        session.deleteConversation(active)

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(session.messages.isEmpty)
    }

    @Test("deleting the ACTIVE conversation starts a fresh empty one")
    func deleteActive() async {
        let store = InMemoryHistoryStore()
        let session = ChatSession(responder: EchoResponder(), history: store)
        await session.send("hello")
        let liveID = session.activeConversationID

        session.deleteConversation(liveID)

        #expect(session.activeConversationID != liveID)
        #expect(session.messages.isEmpty)
        #expect(session.activeTitle == nil)
        #expect(session.conversationSummaries().isEmpty)
    }

    @Test("summaries come back most-recent first and never include the empty active one")
    func summariesOrdering() async {
        let store = InMemoryHistoryStore()
        let session = ChatSession(responder: EchoResponder(), history: store)
        await session.send("first conversation")
        let firstID = session.activeConversationID
        session.startNewConversation()
        await session.send("second conversation")
        let secondID = session.activeConversationID
        session.startNewConversation() // empty — must not appear

        let ids = session.conversationSummaries().map(\.id)
        #expect(ids == [secondID, firstID])
    }
}

// MARK: - Auto-titling

@MainActor
struct ChatSessionTitlingTests {
    @Test("the first completed exchange titles the conversation")
    func titlesFirstExchange() async {
        let store = InMemoryHistoryStore()
        let titler = FakeTitler(result: "  \"Echo chat\". ")
        let session = ChatSession(responder: EchoResponder(), history: store, titler: titler)
        let revisionBefore = session.historyRevision

        await session.send("hello")
        await session.titlingTask?.value

        #expect(titler.calls.count == 1)
        #expect(titler.calls.first?.user == "hello")
        #expect(titler.calls.first?.assistant.contains("echo") == true)
        #expect(session.activeTitle == "Echo chat")
        #expect(session.conversationSummaries().first?.title == "Echo chat")
        #expect(session.historyRevision > revisionBefore + 1) // persist + title
    }

    @Test("send returns without waiting for the titler")
    func titlingNeverBlocksSend() async {
        let store = InMemoryHistoryStore()
        let titler = SlowTitler()
        let session = ChatSession(responder: EchoResponder(), history: store, titler: titler)
        await session.send("hello")
        // Send is done; the slow titler hasn't resolved.
        #expect(session.activeTitle == nil)
        session.titlingTask?.cancel()
    }

    @Test("a throwing titler leaves the conversation untitled and retries next exchange")
    func titlerFailureRetries() async {
        let store = InMemoryHistoryStore()
        let titler = FakeTitler()
        titler.shouldThrow = true
        let session = ChatSession(responder: EchoResponder(), history: store, titler: titler)

        await session.send("first")
        await session.titlingTask?.value
        #expect(session.activeTitle == nil)

        titler.shouldThrow = false
        await session.send("second")
        await session.titlingTask?.value
        #expect(titler.calls.count == 2)
        #expect(session.activeTitle == "Canned Title")
    }

    @Test("an already-titled conversation never re-titles")
    func noRetitle() async {
        let store = InMemoryHistoryStore()
        let titler = FakeTitler()
        let session = ChatSession(responder: EchoResponder(), history: store, titler: titler)
        await session.send("first")
        await session.titlingTask?.value
        await session.send("second")
        await session.titlingTask?.value
        #expect(titler.calls.count == 1)
    }

    @Test("unsanitizable titler output stays untitled with no store write")
    func garbageTitle() async {
        let store = InMemoryHistoryStore()
        let titler = FakeTitler(result: "...")
        let session = ChatSession(responder: EchoResponder(), history: store, titler: titler)
        await session.send("hello")
        await session.titlingTask?.value
        #expect(session.activeTitle == nil)
        #expect(store.setTitleCalls.isEmpty)
    }

    @Test("a failed exchange never calls the titler")
    func failedExchangeNoTitle() async {
        let titler = FakeTitler()
        let session = ChatSession(responder: ThrowingResponder(), history: InMemoryHistoryStore(), titler: titler)
        await session.send("hello")
        await session.titlingTask?.value
        #expect(titler.calls.isEmpty)
    }

    @Test("a title resolving after startNewConversation lands on the ORIGINAL conversation")
    func titleSwitchRace() async {
        let store = InMemoryHistoryStore()
        let titler = HoldableTitler()
        let session = ChatSession(responder: EchoResponder(), history: store, titler: titler)
        await session.send("hello")
        let originalID = session.activeConversationID

        session.startNewConversation()
        titler.release(with: "Late Title")
        await session.titlingTask?.value

        let summaries = session.conversationSummaries()
        #expect(summaries.first { $0.id == originalID }?.title == "Late Title")
        #expect(session.activeTitle == nil) // the NEW conversation stays untitled
    }
}

/// Titler that never resolves within a test's lifetime (cancelled at the end).
private final class SlowTitler: ConversationTitling, @unchecked Sendable {
    func title(forUser _: String, assistant _: String) async throws -> String {
        try await Task.sleep(for: .seconds(60))
        return "never"
    }
}

/// Titler held open until the test releases it — for the switch race.
private final class HoldableTitler: ConversationTitling, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: CheckedContinuation<String, Never>?
    private var releasedValue: String?

    func title(forUser _: String, assistant _: String) async throws -> String {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let value = releasedValue {
                lock.unlock()
                continuation.resume(returning: value)
                return
            }
            pending = continuation
            lock.unlock()
        }
    }

    func release(with value: String) {
        lock.lock()
        releasedValue = value
        let held = pending
        pending = nil
        lock.unlock()
        held?.resume(returning: value)
    }
}
