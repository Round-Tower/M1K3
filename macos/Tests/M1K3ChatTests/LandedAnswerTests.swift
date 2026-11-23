//
//  LandedAnswerTests.swift
//  M1K3ChatTests
//
//  Signed: Kev + claude-opus-5-5, 2026-11-23, Confidence 0.85, Prior: Unknown (new file)

import Foundation
@testable import M1K3Chat
import Testing

struct LandedAnswerTests {
    private func question() -> ChatMessage {
        ChatMessage(role: .user, text: "make me a page", status: .complete)
    }

    private func answer(_ status: ChatMessage.Status = .complete, interrupted: Bool? = nil) -> ChatMessage {
        var message = ChatMessage(role: .assistant, text: "```html\n<p>x</p>\n```", status: status)
        message.interrupted = interrupted
        return message
    }

    @Test("a new, finished assistant message is the landed answer")
    func newAnswer() {
        let asked = question()
        let landed = answer()
        let result = LandedAnswer.completed(in: [asked, landed], after: asked.id, isResponding: false)
        #expect(result?.id == landed.id)
    }

    @Test("a send that returned at once leaves the previous answer: nothing landed")
    func supersededSend() {
        let old = answer()
        #expect(LandedAnswer.completed(in: [question(), old], after: old.id, isResponding: false) == nil)
    }

    @Test("a still-streaming answer has not landed")
    func streaming() {
        let streaming = answer(.streaming)
        #expect(LandedAnswer.completed(in: [question(), streaming], after: nil, isResponding: false) == nil)
        #expect(LandedAnswer.completed(in: [question(), answer()], after: nil, isResponding: true) == nil)
    }

    @Test("a failed or stopped answer has not landed")
    func failedOrStopped() {
        #expect(LandedAnswer.completed(in: [question(), answer(.failed("x"))], after: nil, isResponding: false) == nil)
        #expect(LandedAnswer.completed(in: [question(), answer(interrupted: true)], after: nil, isResponding: false) == nil)
    }

    @Test("a transcript ending on the user's own question has no answer")
    func endsOnQuestion() {
        #expect(LandedAnswer.completed(in: [question()], after: nil, isResponding: false) == nil)
        #expect(LandedAnswer.completed(in: [], after: nil, isResponding: false) == nil)
    }
}
