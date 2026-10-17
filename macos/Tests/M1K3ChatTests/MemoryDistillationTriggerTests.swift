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
//  Review: Kev + claude-fable-5.1, 2026-09-11, Confidence 0.85 — #284: distillAndStore now runs
//  the DistillationAttribution fence, so every `f.exchange(...)` text here was widened past the
//  trivial floor (24 chars / >2 words) and, where a test checks what landed in the store, made
//  to share a real content token with whatever the fixture's scripted fact says ("lives"/"Cork").
//  Tests that only check distiller.callCount/calls (never store contents) only needed the
//  triviality fix.
//  Review: Kev + claude-opus-5-5, 2026-10-17 — #629: the rolling backlog follows the replay window in effect.
//  Review: Kev + claude-opus-5-5, 2026-10-17 — capture off means never: turns sent or delivered with capture off are
//  never distilled later, and switching it off drops the pending backlog too (pinned).

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

    func feedbackComments(conversationID _: UUID) throws -> [UUID: String] {
        [:]
    }

    func allFeedback() throws -> [AnswerFeedback] {
        []
    }

    func deleteAllFeedback() throws {}

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
    /// The memory-capture setting, flippable mid-test.
    let capture: CaptureSwitch

    init(
        script: [Result<[String], Error>] = [.success(["Kev lives in Cork."])],
        autoCapture: Bool = true,
        replayTurns: Int = HistoryWindow.maxTurns
    ) throws {
        capture = CaptureSwitch(autoCapture)
        history = WatermarkHistoryStore()
        distiller = RecordingDistiller(script)
        store = try KnowledgeStore()
        let embedder = HashingEmbeddingService()
        let coordinator = MemoryDistillationCoordinator(
            distiller: distiller,
            ingester: DocumentIngester(store: store, embedder: embedder),
            store: store,
            embedder: embedder,
            selfNames: .none
        )
        session = ChatSession(
            responder: EchoResponder(),
            history: history,
            distillation: coordinator,
            autoCaptureEnabled: { [capture] in capture.isOn },
            replayTurns: { replayTurns }
        )
    }

    func exchange(_ text: String) async {
        await session.send(text)
    }
}

/// The memory-capture setting as a flippable reference (Mutex itself can't sit in a struct).
private final class CaptureSwitch: Sendable {
    private let state: Mutex<Bool>
    init(_ on: Bool) {
        state = Mutex(on)
    }

    var isOn: Bool {
        state.withLock { $0 }
    }

    func set(_ on: Bool) {
        state.withLock { $0 = on }
    }
}

// MARK: - Tests

@MainActor
struct MemoryDistillationTriggerTests {
    @Test("exit after a completed exchange distills and advances the watermark")
    func exitDistills() async throws {
        let f = try Fixture()
        await f.exchange("My sister Aoife lives in Cork these days")
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
        await f.exchange("My sister Aoife lives in Cork these days")
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
        await f.exchange("I live in Cork these days")
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
        await f.exchange("My sister Aoife lives in Cork these days")
        f.session.startNewConversation()
        #expect(f.session.distillationTask == nil)
        #expect(f.distiller.callCount == 0)
    }

    @Test("the watermark lands on the conversation captured at spawn, not the new active one")
    func watermarkLandsOnSpawnConversation() async throws {
        let f = try Fixture()
        await f.exchange("My sister Aoife lives in Cork these days")
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
        await f.exchange("My sister Aoife lives in Cork these days")
        let conversationID = f.session.activeConversationID
        f.session.startNewConversation()
        await f.session.distillationTask?.value
        let firstSlice = f.distiller.calls[0]

        f.session.switchTo(conversationID)
        await f.exchange("My dog is a very friendly collie")
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
        await f.exchange("My sister Aoife lives in Cork these days")
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
            await f.exchange("fact number \(i) about living in Cork")
        }
        await f.session.distillationTask?.value

        #expect(f.distiller.callCount == 1) // distilled WITHOUT an exit
        let id = f.session.activeConversationID
        #expect(try f.history.distilledWatermark(id: id) == f.session.messages.count)
        #expect(try f.store.allItems(kind: .memory).count == 1)
    }

    /// #629: Big's spoken cap replays 8 turns, not 16. Keyed to the old window, a spoken
    /// session's early turns sat ~12 messages neither replayed nor distilled.
    @Test("the rolling backlog follows the replay window in effect, not the widest one")
    func rollingFollowsTheWindowInEffect() {
        #expect(ChatSession.shouldRollingDistill(messageCount: 12, watermark: 0, replayTurns: 8))
        #expect(!ChatSession.shouldRollingDistill(messageCount: 11, watermark: 0, replayTurns: 8))
        #expect(!ChatSession.shouldRollingDistill(messageCount: 12, watermark: 0, replayTurns: HistoryWindow.maxTurns))
    }

    @Test("a session on a narrower window distills mid-stream sooner")
    func narrowWindowDistillsSooner() async throws {
        let f = try Fixture(replayTurns: 8)
        for i in 1 ... 6 { // 12 messages: past 8 + 4, under the default 16 + 4
            await f.exchange("fact number \(i) about living in Cork")
        }
        await f.session.distillationTask?.value
        #expect(f.distiller.callCount == 1)
    }

    /// 2026-10-17: a voice-rig run with capture OFF was distilled anyway at the next normal
    /// launch: its turns sat past the watermark, and the launch catch-up took them.
    @Test("turns exchanged with capture off are never distilled later, even once capture is back on")
    func captureOffTurnsStayUndistilled() async throws {
        let f = try Fixture(autoCapture: false)
        for i in 1 ... 3 {
            await f.exchange("my private fact \(i) about living in Cork")
        }
        let id = f.session.activeConversationID
        #expect(try f.history.distilledWatermark(id: id) == f.session.messages.count)

        f.capture.set(true) // capture back on: leaving the chat distills nothing old
        f.session.startNewConversation()
        await f.session.distillationTask?.value
        #expect(f.distiller.callCount == 0)
    }

    /// The design call (review fold): capture is one integer watermark, so switching it off and
    /// sending drops the not-yet-distilled turns from before the switch too. Off means off.
    @Test("switching capture off and sending drops the undistilled turns from before the switch as well")
    func captureOffDropsThePendingBacklog() async throws {
        let f = try Fixture()
        for i in 1 ... 2 { // under the rolling backlog: nothing distilled yet
            await f.exchange("an earlier fact \(i) about living in Cork")
        }
        f.capture.set(false)
        await f.exchange("a private fact about living in Cork")
        f.capture.set(true)
        f.session.startNewConversation()
        await f.session.distillationTask?.value
        #expect(f.distiller.callCount == 0)
    }

    @Test("a background answer that lands with capture off is skipped too")
    func captureOffBackgroundAnswerIsSkipped() async throws {
        let f = try Fixture(autoCapture: false)
        await f.exchange("look into the Cork weather history for me")
        await f.session.deliverBackgroundAnswer("Cork has had a mild autumn on record.")
        let id = f.session.activeConversationID
        #expect(try f.history.distilledWatermark(id: id) == f.session.messages.count)
    }

    @Test("a short session does NOT distill mid-stream — cost stays off the hot path")
    func shortSessionNoRollingDistill() async throws {
        let f = try Fixture()
        for i in 1 ... 3 {
            await f.exchange("my fact \(i) noted today")
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
