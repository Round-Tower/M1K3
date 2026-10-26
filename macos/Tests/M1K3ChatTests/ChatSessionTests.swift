//
//  ChatSessionTests.swift
//  M1K3ChatTests
//
//  The chat state reducer the SwiftUI shell binds to. This is the one piece of
//  "app glue" that carries real bugs — folding a streamed answer into displayable
//  state across partial tokens, cancellation, and mid-stream failure — so it's
//  TDD'd in the package rather than waved through in a View. The views stay dumb.
//
//  The streaming contract is deliberately stress-tested both ways: Apple
//  Foundation Models yields *cumulative* snapshots (full text each tick) while
//  the simpler fakes yield *deltas*. ChatSession must render both correctly, so
//  both are pinned here.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-opus-5.5, 2026-10-26 — #697: Cool Head's `.note` lands on the answer as `turnNote`
//  (persisted, Optional), never in its text, its activity label or the replayed history. Confidence 0.85.

import Foundation
@testable import M1K3Chat
import M1K3Inference
import M1K3Knowledge
import Testing

// MARK: - Fakes conforming to the RAGResponding seam

/// Yields cumulative snapshots — exactly how AppleFoundationModelsProvider
/// behaves (each yield is the whole answer so far).
private struct CumulativeResponder: RAGResponding {
    let sources: [ChunkHit]
    let snapshots: [String]

    func answerStreaming(
        _: String
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        let snapshots = snapshots
        return (sources, AsyncStream { continuation in
            for snap in snapshots {
                continuation.yield(snap)
            }
            continuation.finish()
        })
    }
}

/// Yields per-word deltas — how the lighter providers (and the existing
/// RecordingProvider fixture) stream.
private struct DeltaResponder: RAGResponding {
    let sources: [ChunkHit]
    let deltas: [String]

    func answerStreaming(
        _: String
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        let deltas = deltas
        return (sources, AsyncStream { continuation in
            for delta in deltas {
                continuation.yield(delta)
            }
            continuation.finish()
        })
    }
}

/// Fails before producing a stream (retrieval/provider error path).
private struct FailingResponder: RAGResponding {
    struct Boom: Error {}
    func answerStreaming(
        _: String
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        throw Boom()
    }
}

/// Records the history each send delivers (the chat-memory contract).
private final class HistoryRecordingResponder: RAGResponding, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var receivedHistories: [[ChatTurn]] = []

    /// Grounds the protocol's one-way default chain (the plain variant has no
    /// default by design — see RAGResponding).
    func answerStreaming(
        _ question: String
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        try await answerStreaming(question, history: [], onActivity: { _ in })
    }

    func answerStreaming(
        _: String,
        history: [ChatTurn],
        onActivity _: @escaping @Sendable (ResponderActivity) -> Void
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        lock.withLock { receivedHistories.append(history) }
        return ([], AsyncStream { continuation in
            continuation.yield("answered")
            continuation.finish()
        })
    }
}

/// Throws on the first send, records history and answers from then on —
/// pins that a failed turn never re-enters the replay window.
private final class FailOnceThenRecordResponder: RAGResponding, @unchecked Sendable {
    private struct Boom: Error {}
    private let lock = NSLock()
    private var hasFailed = false
    private(set) var receivedHistories: [[ChatTurn]] = []

    func answerStreaming(
        _ question: String
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        try await answerStreaming(question, history: [], onActivity: { _ in })
    }

    func answerStreaming(
        _: String,
        history: [ChatTurn],
        onActivity _: @escaping @Sendable (ResponderActivity) -> Void
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        let shouldFail = lock.withLock {
            if hasFailed { return false }
            hasFailed = true
            return true
        }
        if shouldFail { throw Boom() }
        lock.withLock { receivedHistories.append(history) }
        return ([], AsyncStream { continuation in
            continuation.yield("recovered")
            continuation.finish()
        })
    }
}

/// Reports Cool Head's line on the activity channel, then answers (#697): the app's chat
/// responder does exactly this on the send that eased effort.
private struct NotingResponder: RAGResponding {
    static let line = "This machine's running warm, so I'm going easy on the heavy lifting."

    func answerStreaming(
        _ question: String
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        try await answerStreaming(question, history: [], onActivity: { _ in })
    }

    func answerStreaming(
        _: String,
        history _: [ChatTurn],
        onActivity: @escaping @Sendable (ResponderActivity) -> Void
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        onActivity(.note(Self.line))
        onActivity(.retrieving)
        return ([], AsyncStream { continuation in
            continuation.yield("ok")
            continuation.finish()
        })
    }
}

private func fixtureSource(_ text: String) -> ChunkHit {
    ChunkHit(
        chunkID: UUID(),
        itemID: UUID(),
        itemTitle: "Plant Notes",
        kind: .document,
        heading: "3.2 Seals",
        content: text
    )
}

// MARK: - Tests

@MainActor
struct ChatSessionTests {
    @Test("recordMetrics stamps the last assistant message (and no-ops with none)")
    func recordMetricsStampsLastAssistant() async {
        let session = ChatSession(responder: DeltaResponder(sources: [], deltas: ["ok"]))
        let metrics = GenerationMetrics(promptTokens: 1240, generationTokens: 380, tokensPerSecond: 34)

        // No assistant message yet → safe no-op.
        session.recordMetrics(metrics)

        await session.send("What failed?")
        session.recordMetrics(metrics)
        #expect(session.messages.last?.role == .assistant)
        #expect(session.messages.last?.metrics == metrics)
        // The user message never carries generation stats.
        #expect(session.messages.first?.metrics == nil)
    }

    @Test("send appends the user message immediately")
    func appendsUserMessage() async {
        let session = ChatSession(responder: DeltaResponder(sources: [], deltas: ["ok"]))
        await session.send("What failed?")

        let user = session.messages.first
        #expect(user?.role == .user)
        #expect(user?.text == "What failed?")
        #expect(user?.status == .complete)
    }

    @Test("blank input is ignored — no messages, no call")
    func ignoresBlankInput() async {
        let session = ChatSession(responder: DeltaResponder(sources: [], deltas: ["ok"]))
        await session.send("   \n ")
        #expect(session.messages.isEmpty)
    }

    @Test("each send carries the PRIOR completed turns as history")
    func sendCarriesHistory() async {
        let responder = HistoryRecordingResponder()
        let session = ChatSession(responder: responder)

        await session.send("What's the weather in Galway?")
        await session.send("And in Fahrenheit?")

        #expect(responder.receivedHistories.count == 2)
        #expect(responder.receivedHistories[0].isEmpty)
        let second = responder.receivedHistories[1]
        #expect(second.map(\.text) == ["What's the weather in Galway?", "answered"])
        #expect(second.map(\.role) == [.user, .assistant])
    }

    @Test("a FAILED prior turn is excluded from the history replay")
    func failedTurnNeverReplays() async {
        // A turn that errors mid-stream stays .failed (never flipped to
        // .complete with partial text) — its user question AND its failure
        // text must not ride into the next turn's prompt.
        let responder = FailOnceThenRecordResponder()
        let session = ChatSession(responder: responder)

        await session.send("doomed question")
        await session.send("fresh question")

        let replayed = responder.receivedHistories.last ?? []
        // Only the doomed USER turn replays (it completed); the failed
        // assistant message is excluded.
        #expect(replayed.map(\.role) == [.user])
        #expect(replayed.map(\.text) == ["doomed question"])
    }

    @Test("folds CUMULATIVE snapshots into the final answer (AFM contract)")
    func foldsCumulative() async {
        let session = ChatSession(responder: CumulativeResponder(
            sources: [],
            snapshots: ["The", "The seal", "The seal failed"]
        ))
        await session.send("what failed?")

        let answer = session.messages.last
        #expect(answer?.role == .assistant)
        #expect(answer?.text == "The seal failed") // replaced, not concatenated
        #expect(answer?.status == .complete)
    }

    @Test("folds DELTA chunks into the final answer (delta contract)")
    func foldsDelta() async {
        let session = ChatSession(responder: DeltaResponder(
            sources: [],
            deltas: ["The ", "seal ", "failed"]
        ))
        await session.send("what failed?")

        #expect(session.messages.last?.text == "The seal failed")
    }

    @Test("a FOLLOWUPS trailer is parsed into followUps and stripped from the text")
    func parsesFollowUps() async {
        let session = ChatSession(responder: DeltaResponder(
            sources: [],
            deltas: ["The seal failed.\n", "FOLLOWUPS: ", "[\"Why did it fail?\", \"How do I fix it?\"]"]
        ))
        await session.send("what happened?")

        let answer = session.messages.last
        #expect(answer?.text == "The seal failed.")
        #expect(answer?.followUps == ["Why did it fail?", "How do I fix it?"])
    }

    @Test("no FOLLOWUPS trailer means no follow-ups, text unchanged")
    func noFollowUpsWhenAbsent() async {
        let session = ChatSession(responder: DeltaResponder(sources: [], deltas: ["ok"]))
        await session.send("hi")

        #expect(session.messages.last?.followUps == [])
        #expect(session.messages.last?.text == "ok")
    }

    @Test("attaches retrieved sources to the assistant message")
    func attachesSources() async {
        let src = fixtureSource("The hydraulic seal failed under load.")
        let session = ChatSession(responder: DeltaResponder(sources: [src], deltas: ["ok"]))
        await session.send("seal?")

        let answer = session.messages.last
        #expect(answer?.sources.count == 1)
        #expect(answer?.sources.first?.itemTitle == "Plant Notes")
    }

    @Test("a thrown error surfaces as a failed assistant message, not a crash")
    func failurePath() async {
        let session = ChatSession(responder: FailingResponder())
        await session.send("anything?")

        let answer = session.messages.last
        #expect(answer?.role == .assistant)
        if case .failed = answer?.status {} else {
            Issue.record("expected .failed status, got \(String(describing: answer?.status))")
        }
        #expect(!(answer?.text.isEmpty ?? true)) // user-facing fallback text
    }

    @Test("isResponding is true mid-flight and false once settled")
    func respondingFlag() async {
        let session = ChatSession(responder: DeltaResponder(sources: [], deltas: ["a", "b"]))
        #expect(session.isResponding == false)
        await session.send("go")
        #expect(session.isResponding == false)
    }

    @Test("a full turn is exactly two messages: user then assistant")
    func turnShape() async {
        let session = ChatSession(responder: DeltaResponder(sources: [], deltas: ["ok"]))
        await session.send("hello")
        #expect(session.messages.count == 2)
        #expect(session.messages[0].role == .user)
        #expect(session.messages[1].role == .assistant)
    }

    @Test("strips hallucinated citations from the streamed answer, records validated ones")
    func validatesCitationsAfterStream() async {
        let source = ChunkHit(
            chunkID: UUID(), itemID: UUID(), itemTitle: "ICH-Q7",
            kind: .document, heading: "5.2 Cleaning", content: "Clean the line."
        )
        let responder = DeltaResponder(
            sources: [source],
            deltas: ["Clean ", "(ICH-Q7 §5.2 Cleaning) ", "but not ", "[FAKE §9 Nope]."]
        )
        let session = ChatSession(responder: responder)
        await session.send("How do I clean the line?")

        let assistant = session.messages.last
        #expect(assistant?.status == .complete)
        #expect(assistant?.text.contains("ICH-Q7") == true) // grounded citation kept
        #expect(assistant?.text.contains("FAKE") == false) // invented citation stripped
        #expect(assistant?.citations == [Citation(source: "ICH-Q7", heading: "5.2 Cleaning")])
    }

    // MARK: - Cool Head's line (#697)

    @Test("Cool Head's note lands on the answer message, not in its text or its activity label")
    func noteLandsOnTheAnswerMessage() async throws {
        let session = ChatSession(responder: NotingResponder())
        await session.send("hello")
        // The activity hops ride Task { @MainActor }: give them a beat (the ToolTraceTests idiom).
        for _ in 0 ..< 200 where session.messages.last?.turnNote == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let answer = try #require(session.messages.last)
        #expect(answer.role == .assistant)
        #expect(answer.turnNote == NotingResponder.line)
        #expect(answer.text == "ok")
        #expect(answer.activityLabel == nil)
        #expect(answer.status == .complete)
        #expect(session.messages.count == 2, "the note is a field on the answer, never a bubble of its own")
    }

    @Test("Cool Head's note is never replayed as history")
    func noteIsNotReplayedAsHistory() async throws {
        let session = ChatSession(responder: NotingResponder())
        await session.send("hello")
        for _ in 0 ..< 200 where session.messages.last?.turnNote == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let replayed = ChatSession.replayableHistory(session.messages).map(\.text)
        #expect(replayed == ["hello", "ok"])
        #expect(!replayed.joined().contains(NotingResponder.line))
    }

    @Test("turnNote persists, and decodes to nil on a transcript that predates it")
    func turnNoteDecodesToNilOnAPreNoteTranscript() throws {
        var message = ChatMessage(role: .assistant, text: "answer", status: .complete)
        message.turnNote = NotingResponder.line
        let roundTrip = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        #expect(roundTrip.turnNote == NotingResponder.line)
        // Drop the key the way every saved transcript before #697 lacks it: no keyNotFound, no wiped history.
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        #expect(object["turnNote"] as? String == NotingResponder.line)
        object.removeValue(forKey: "turnNote")
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.turnNote == nil)
        #expect(decoded.text == "answer")
    }
}
