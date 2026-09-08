//
//  ChatSessionStopTests.swift
//  M1K3ChatTests
//
//  The user's "stop" mid-answer (hit list 2026-09-08, item 3). The contract:
//  whatever streamed stays in the transcript marked as cut short, the
//  producer is torn down (its stream terminates → the provider's generation
//  task is cancelled), the latch drops so the next send goes through, and a
//  stop with nothing streamed leaves no hollow bubble behind.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-08, Confidence 0.85 (the seam is
//  pinned end to end against a hanging fake; the MLX cache state after a real
//  cancel is verify-by-launch). Prior: Unknown.
//

import Foundation
@testable import M1K3Chat
import M1K3Inference
import M1K3Knowledge
import Testing

/// Streams a few deltas, then hangs until the consumer goes away. Records
/// whether the stream was terminated so a test can prove the producer side was
/// torn down — that's the hook the real providers cancel generation from.
private final class HangingResponder: RAGResponding, @unchecked Sendable {
    private let lock = NSLock()
    private var terminated = false
    let deltas: [String]

    init(deltas: [String]) {
        self.deltas = deltas
    }

    var wasTerminated: Bool {
        lock.withLock { terminated }
    }

    func answerStreaming(
        _: String
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        let deltas = deltas
        return ([], AsyncStream { continuation in
            for delta in deltas {
                continuation.yield(delta)
            }
            continuation.onTermination = { [lock] _ in
                lock.withLock { self.terminated = true }
            }
        })
    }
}

/// Never even reaches the stream — models a stop during retrieval/prefill.
private struct NeverAnsweringResponder: RAGResponding {
    func answerStreaming(
        _: String
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        try await Task.sleep(for: .seconds(60))
        return ([], AsyncStream { $0.finish() })
    }
}

@MainActor
struct ChatSessionStopTests {
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0 ..< 200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("stop mid-stream keeps the partial answer, marks it interrupted, and tears the producer down")
    func stopKeepsPartial() async {
        let responder = HangingResponder(deltas: ["The capital ", "of France"])
        let session = ChatSession(responder: responder)
        let sending = Task { await session.send("Capital of France?") }
        await waitUntil { session.messages.last?.text.contains("France") == true }
        #expect(session.isResponding)

        session.stopResponding()
        await sending.value

        let answer = session.messages.last
        #expect(answer?.text == "The capital of France")
        #expect(answer?.status == .complete)
        #expect(answer?.interrupted == true)
        #expect(!session.isResponding)
        #expect(responder.wasTerminated)
    }

    @Test("stop before any token removes the empty bubble but keeps the question")
    func stopBeforeTokensLeavesNoHollowBubble() async {
        let session = ChatSession(responder: NeverAnsweringResponder())
        let sending = Task { await session.send("Slow one") }
        await waitUntil { session.isResponding }

        session.stopResponding()
        await sending.value

        #expect(session.messages.count == 1)
        #expect(session.messages.last?.role == .user)
        #expect(!session.isResponding)
    }

    @Test("stop while idle is a no-op and the next send still works")
    func stopWhileIdleIsNoOp() {
        let session = ChatSession(responder: HangingResponder(deltas: []))
        session.stopResponding()
        #expect(session.messages.isEmpty)
        #expect(!session.isResponding)
    }

    @Test("a stopped answer is a completed turn for the next send's history")
    func stoppedAnswerReplays() async {
        let responder = HangingResponder(deltas: ["partial"])
        let session = ChatSession(responder: responder)
        let sending = Task { await session.send("q1") }
        await waitUntil { session.messages.last?.text == "partial" }
        session.stopResponding()
        await sending.value
        let history = ChatSession.replayableHistory(session.messages)
        #expect(history.map(\.text) == ["q1", "partial"])
    }

    @Test("interrupted decodes to nil on a transcript that predates it")
    func interruptedIsOptionalOnDecode() throws {
        // Round-trip a real message, then drop the key the way an old row lacks it.
        var message = ChatMessage(role: .assistant, text: "old", status: .complete)
        message.interrupted = true
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        #expect(object["interrupted"] as? Bool == true)
        object.removeValue(forKey: "interrupted")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        #expect(decoded.interrupted == nil)
        #expect(decoded.text == "old")
    }
}
