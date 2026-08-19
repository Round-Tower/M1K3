//
//  MemoryDistillationTriggerTests.swift
//  M1K3ChatTests
//
//  The distillation trigger: fires on conversation EXIT (new/switch) over the
//  post-watermark slice, advances the watermark only on success, never spawns
//  when auto-capture is off, and lands its watermark on the conversation
//  captured at spawn (the auto-titling blueprint). deleteConversation never
//  distills — deletion is discard intent.
//
//  Signed: Kev + claude-fable-5, 2026-06-12, Confidence 0.9, Prior: Unknown

import Foundation
@testable import M1K3Chat
@testable import M1K3Knowledge
import Synchronization
import Testing

// MARK: - Fakes

private final class WatermarkHistoryStore: ChatHistoryPersisting, @unchecked Sendable {
    private struct Row {
        var title: String?
        var createdAt: Date
        var updatedAt: Date
        var messages: [ChatMessage]
    }

    private let lock = NSLock()
    private var rows: [UUID: Row] = [:]
    private var watermarks: [UUID: Int] = [:]

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
        guard var row = rows[id] else { return }
        row.title = title
        rows[id] = row
    }

    @discardableResult
    func delete(id: UUID) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        watermarks.removeValue(forKey: id)
        return rows.removeValue(forKey: id) != nil
    }

    func distilledWatermark(id: UUID) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        return watermarks[id] ?? 0
    }

    func recordFeedback(_: AnswerFeedback) throws {}
    func feedbackVerdicts(conversationID _: UUID) throws -> [UUID: FeedbackVerdict] {
        [:]
    }

    func allFeedback() throws -> [AnswerFeedback] {
        []
    }

    func setDistilledWatermark(id: UUID, count: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        guard rows[id] != nil else { return }
        watermarks[id] = count
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

private struct Boom: Error {}

/// Records every slice it's handed; pops scripted results (last one sticks).
/// Mutex, not NSLock — lock()/unlock() are unavailable in async contexts.
private final class RecordingDistiller: MemoryDistilling, Sendable {
    private struct State {
        var script: [Result<[String], Error>]
        var calls: [[ChatTurn]] = []
    }

    private let state: Mutex<State>

    init(_ script: [Result<[String], Error>]) {
        state = Mutex(State(script: script))
    }

    func distill(turns: [ChatTurn]) async throws -> [DistilledFact] {
        let result = state.withLock { state -> Result<[String], Error> in
            state.calls.append(turns)
            return state.script.count > 1 ? state.script.removeFirst() : state.script[0]
        }
        // Untyped scripts land as `.note`, exactly like a bare "FACT:" line.
        return try result.get().map { DistilledFact(text: $0) }
    }

    var calls: [[ChatTurn]] {
        state.withLock { $0.calls }
    }

    var callCount: Int {
        state.withLock { $0.calls.count }
    }
}

// MARK: - Fixture

@MainActor
private struct Fixture {
    let session: ChatSession
    let history: WatermarkHistoryStore
    let distiller: RecordingDistiller
    let store: KnowledgeStore

    init(
        script: [Result<[String], Error>] = [.success(["Kev lives in Cork."])],
        autoCapture: Bool = true
    ) throws {
        history = WatermarkHistoryStore()
        distiller = RecordingDistiller(script)
        store = try KnowledgeStore()
        let embedder = HashingEmbeddingService()
        let coordinator = MemoryDistillationCoordinator(
            distiller: distiller,
            ingester: DocumentIngester(store: store, embedder: embedder),
            store: store,
            embedder: embedder
        )
        session = ChatSession(
            responder: EchoResponder(),
            history: history,
            distillation: coordinator,
            autoCaptureEnabled: { autoCapture }
        )
    }

    func exchange(_ text: String) async {
        await session.send(text)
    }
}

// MARK: - Tests

@MainActor
struct MemoryDistillationTriggerTests {
    @Test("exit after a completed exchange distills and advances the watermark")
    func exitDistills() async throws {
        let f = try Fixture()
        await f.exchange("My sister is called Aoife")
        let conversationID = f.session.activeConversationID
        let messageCount = f.session.messages.count

        f.session.startNewConversation()
        await f.session.distillationTask?.value

        #expect(f.distiller.callCount == 1)
        #expect(try f.history.distilledWatermark(id: conversationID) == messageCount)
        #expect(try f.store.allItems(kind: .memory).count == 1)
    }

    @Test("re-exiting with no new content never re-distills")
    func noNewContentNoSpawn() async throws {
        let f = try Fixture()
        await f.exchange("My sister is called Aoife")
        let conversationID = f.session.activeConversationID

        f.session.startNewConversation()
        await f.session.distillationTask?.value
        #expect(f.distiller.callCount == 1)

        // Switch back and exit again — watermark covers everything.
        f.session.switchTo(conversationID)
        f.session.startNewConversation()
        await f.session.distillationTask?.value
        #expect(f.distiller.callCount == 1)
    }

    @Test("a throwing distiller leaves the watermark — the next exit retries the slice")
    func throwKeepsWatermark() async throws {
        let f = try Fixture(script: [.failure(Boom()), .success(["Kev lives in Cork."])])
        await f.exchange("I live in Cork")
        let conversationID = f.session.activeConversationID

        f.session.startNewConversation()
        await f.session.distillationTask?.value
        #expect(try f.history.distilledWatermark(id: conversationID) == 0)

        // Return and exit again: the same slice retries and now succeeds.
        f.session.switchTo(conversationID)
        f.session.startNewConversation()
        await f.session.distillationTask?.value
        #expect(f.distiller.callCount == 2)
        #expect(try f.history.distilledWatermark(id: conversationID) > 0)
    }

    @Test("auto-capture off → exit never distills")
    func toggleOffNeverSpawns() async throws {
        let f = try Fixture(autoCapture: false)
        await f.exchange("My sister is called Aoife")
        f.session.startNewConversation()
        #expect(f.session.distillationTask == nil)
        #expect(f.distiller.callCount == 0)
    }

    @Test("the watermark lands on the conversation captured at spawn, not the new active one")
    func watermarkLandsOnSpawnConversation() async throws {
        let f = try Fixture()
        await f.exchange("My sister is called Aoife")
        let original = f.session.activeConversationID
        let originalCount = f.session.messages.count

        f.session.startNewConversation()
        let fresh = f.session.activeConversationID
        await f.session.distillationTask?.value

        #expect(try f.history.distilledWatermark(id: original) == originalCount)
        #expect(try f.history.distilledWatermark(id: fresh) == 0)
    }

    @Test("only the post-watermark slice reaches the distiller")
    func onlyFreshSliceFed() async throws {
        let f = try Fixture()
        await f.exchange("My sister is called Aoife")
        let conversationID = f.session.activeConversationID
        f.session.startNewConversation()
        await f.session.distillationTask?.value
        let firstSlice = f.distiller.calls[0]

        f.session.switchTo(conversationID)
        await f.exchange("My dog is a collie")
        f.session.startNewConversation()
        await f.session.distillationTask?.value

        #expect(f.distiller.callCount == 2)
        let secondSlice = f.distiller.calls[1]
        #expect(secondSlice.contains { $0.text.contains("collie") })
        #expect(!secondSlice.contains { $0.text.contains("Aoife") })
        #expect(firstSlice.contains { $0.text.contains("Aoife") })
    }

    @Test("a transcript with no completed exchange (lone user turn) never distills")
    func loneUserTurnNoSpawn() throws {
        let f = try Fixture()
        // Seed a conversation whose only content is a user message.
        let id = UUID()
        f.history.seedConversation(
            id: id,
            messages: [ChatMessage(role: .user, text: "hello?", status: .complete)]
        )
        f.session.switchTo(id)
        f.session.startNewConversation()
        #expect(f.session.distillationTask == nil)
        #expect(f.distiller.callCount == 0)
    }

    @Test("deleting a conversation never distills it — deletion is discard intent")
    func deleteNeverDistills() async throws {
        let f = try Fixture()
        await f.exchange("My sister is called Aoife")
        f.session.deleteConversation(f.session.activeConversationID)
        #expect(f.session.distillationTask == nil)
        #expect(f.distiller.callCount == 0)
    }

    @Test("a session without a coordinator behaves exactly as before (nil seam)")
    func nilSeamIsInert() async {
        let history = WatermarkHistoryStore()
        let session = ChatSession(responder: EchoResponder(), history: history)
        await session.send("My sister is called Aoife")
        session.startNewConversation()
        #expect(session.distillationTask == nil)
    }

    // MARK: - Rolling (mid-session) distillation

    @Test("rolling policy: fires only once the undistilled backlog outgrows the window")
    func rollingPolicyThreshold() {
        let n = ChatSession.rollingDistillBacklog
        #expect(!ChatSession.shouldRollingDistill(messageCount: n - 1, watermark: 0))
        #expect(ChatSession.shouldRollingDistill(messageCount: n, watermark: 0))
        // The watermark offsets the backlog — only UN-distilled turns count.
        #expect(!ChatSession.shouldRollingDistill(messageCount: n + 5, watermark: 6))
        #expect(ChatSession.shouldRollingDistill(messageCount: n + 6, watermark: 6))
    }

    @Test("a long live session distills mid-stream, before any exit (no more mid-session amnesia)")
    func rollingDistillsMidSession() async throws {
        let f = try Fixture()
        // Each echo exchange = 2 messages; drive past the rolling backlog WITHOUT
        // ever switching or exiting the conversation.
        let exchanges = ChatSession.rollingDistillBacklog / 2
        for i in 1 ... exchanges {
            await f.exchange("fact number \(i)")
        }
        await f.session.distillationTask?.value

        #expect(f.distiller.callCount == 1) // distilled WITHOUT an exit
        let id = f.session.activeConversationID
        #expect(try f.history.distilledWatermark(id: id) == f.session.messages.count)
        #expect(try f.store.allItems(kind: .memory).count == 1)
    }

    @Test("a short session does NOT distill mid-stream — cost stays off the hot path")
    func shortSessionNoRollingDistill() async throws {
        let f = try Fixture()
        for i in 1 ... 3 {
            await f.exchange("fact \(i)")
        } // 6 messages, under the backlog
        #expect(f.session.distillationTask == nil) // nothing fired mid-session
        #expect(f.distiller.callCount == 0)

        f.session.startNewConversation() // exit still distills, exactly as before
        await f.session.distillationTask?.value
        #expect(f.distiller.callCount == 1)
    }
}

private extension WatermarkHistoryStore {
    func seedConversation(id: UUID, messages: [ChatMessage]) {
        try? save(id: id, messages: messages, updatedAt: Date())
    }
}
