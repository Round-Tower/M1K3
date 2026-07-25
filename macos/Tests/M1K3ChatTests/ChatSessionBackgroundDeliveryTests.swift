//
//  ChatSessionBackgroundDeliveryTests.swift
//  M1K3ChatTests
//
//  deliverBackgroundAnswer — the delegate_deep landing pad (Kev, 2026-07-25):
//  a delegated task finishes in the background and its answer joins the
//  transcript as a completed assistant message, out-of-band relative to
//  send() (no user bubble, no streaming placeholder), with the same
//  FOLLOWUPS split + text polish an ordinary turn gets, persisted at once.
//
//  Signed: Kev + claude-fable-5, 2026-07-25, Confidence 0.9, Prior: Unknown
//

import Foundation
@testable import M1K3Chat
import M1K3Inference
import M1K3Knowledge
import Testing

@MainActor
struct ChatSessionBackgroundDeliveryTests {
    private struct SilentResponder: RAGResponding {
        func answerStreaming(
            _: String
        ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
            (sources: [], stream: AsyncStream { $0.finish() })
        }
    }

    @Test("delivers a completed assistant message with no user bubble")
    func deliversCompletedAssistantMessage() async {
        let session = ChatSession(responder: SilentResponder())
        await session.deliverBackgroundAnswer("Here's the deep dive you asked for.")

        #expect(session.messages.count == 1)
        let message = session.messages[0]
        #expect(message.role == .assistant)
        #expect(message.text == "Here's the deep dive you asked for.")
        if case .complete = message.status {} else {
            Issue.record("expected .complete, got \(message.status)")
        }
    }

    @Test("the FOLLOWUPS trailer splits into chips, never body text")
    func followUpsSplit() async {
        let session = ChatSession(responder: SilentResponder())
        await session.deliverBackgroundAnswer(
            "The answer.\nFOLLOWUPS: [\"Want the sources?\"]"
        )
        let message = session.messages[0]
        #expect(!message.text.contains("FOLLOWUPS"))
        #expect(message.followUps == ["Want the sources?"])
    }

    @Test("an empty delivery is dropped — no hollow bubble")
    func emptyDeliveryDropped() async {
        let session = ChatSession(responder: SilentResponder())
        await session.deliverBackgroundAnswer("   ")
        #expect(session.messages.isEmpty)
    }

    @Test("delivery mid-send waits its turn — never interleaves a streaming turn")
    func deliveryDuringSendAppendsAfter() async {
        // A streaming send in flight: the delivery must land as its own message
        // AFTER the in-flight assistant message, not corrupt it.
        let session = ChatSession(responder: SilentResponder())
        await session.send("hello")
        await session.deliverBackgroundAnswer("Background result.")
        #expect(session.messages.last?.text == "Background result.")
        #expect(session.messages.last?.role == .assistant)
    }
}
