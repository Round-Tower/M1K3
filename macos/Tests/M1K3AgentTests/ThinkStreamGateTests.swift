//
//  ThinkStreamGateTests.swift
//  M1K3AgentTests
//
//  The native loop streams a model turn's tokens BEFORE knowing whether the
//  turn ends in text or tool calls. The gate makes that safe: the think phase
//  (tags included) is emitted live — it routes to the reasoning disclosure —
//  while post-think text is held back until the outcome is known (.text →
//  flush as the answer; .toolCalls → discard, the transcript keeps it).
//
//  Signed: Kev + claude-fable-5, 2026-06-10, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-10-09, Confidence 0.85 — pins the PRE-OPENED
//  template contract (Qwen3.5, Lil again since #517): the gate has no notion of
//  "pre-opened"; the SESSION yields the synthetic `<think>` as token zero
//  (MLXToolTurnSession.sendHeld, MLXBrainProvider.generateStreaming) so the gate
//  is live from the model's first token and closes on its lone `</think>`. A
//  reasoning-only turn fires no answer token (the responder's empty-answer
//  fallback relies on that), and a redundant model-emitted opener can reach the
//  disclosure but never the bubble. Green from the start: these pin wiring that
//  already held, written while chasing a reported bubble leak that the source
//  does not reproduce. Test names kept under the lint limit; Confidence now 0.85.
//

import Foundation
@testable import M1K3Agent
import Testing

struct ThinkStreamGateTests {
    private func feedAll(_ tokens: [String]) -> (live: String, gate: ThinkStreamGate) {
        var gate = ThinkStreamGate()
        var live = ""
        for token in tokens {
            live += gate.feed(token)
        }
        return (live, gate)
    }

    private func feedAllWithAnswer(_ tokens: [String]) -> (live: String, answer: String, gate: ThinkStreamGate) {
        var gate = ThinkStreamGate()
        var live = ""
        var answer = ""
        for token in tokens {
            live += gate.feed(token, onAnswerToken: { answer += $0 })
        }
        return (live, answer, gate)
    }

    @Test("the think phase streams live, tags included; the answer is held back")
    func thinkStreamsLive() {
        var (live, gate) = feedAll(["<think>", "checking", " tools", "</think>", "It's sunny."])
        #expect(live == "<think>checking tools</think>")
        #expect(gate.flushRemainder() == "It's sunny.")
    }

    @Test("a non-thinking turn emits nothing live; everything is in the remainder")
    func noThinkAllHeld() {
        var (live, gate) = feedAll(["The answer ", "is 42."])
        #expect(live == "")
        #expect(gate.flushRemainder() == "The answer is 42.")
    }

    @Test("a close tag split across tokens is still caught")
    func splitCloseTag() {
        var (live, gate) = feedAll(["<think>plan</th", "ink>answer"])
        #expect(live == "<think>plan</think>")
        #expect(gate.flushRemainder() == "answer")
    }

    @Test("whitespace before the opening tag still engages live mode")
    func leadingWhitespace() {
        var (live, gate) = feedAll(["\n<think>plan</think>done"])
        #expect(live == "<think>plan</think>")
        #expect(gate.flushRemainder() == "done")
    }

    @Test("an unclosed think flushes its tail as the remainder")
    func unclosedThink() {
        var (live, gate) = feedAll(["<think>endless thought"])
        #expect(live.hasPrefix("<think>"))
        #expect(live + gate.flushRemainder() == "<think>endless thought")
    }

    @Test("a bare </think> with no opener buffers as plain text, never streams live")
    func bareCloseWithoutOpen() {
        // Only reachable when the synthetic opener is NOT prepended (a
        // non-pre-opening template emitting a stray close): it must be held
        // for the outcome like any other non-think text.
        var (live, gate) = feedAll(["</think>just an answer"])
        #expect(live.isEmpty)
        #expect(gate.flushRemainder() == "</think>just an answer")
    }

    @Test("answer tokens stream live after </think> via the callback")
    func answerStreamsLive() {
        var (live, answer, gate) = feedAllWithAnswer(["<think>", "plan", "</think>", "The", " answer."])
        #expect(live == "<think>plan</think>")
        #expect(answer == "The answer.")
        #expect(gate.flushRemainder() == "The answer.")
    }

    @Test("a non-thinking turn streams to answer via callback")
    func noThinkAnswer() {
        var (live, answer, gate) = feedAllWithAnswer(["Plain ", "answer text."])
        #expect(live.isEmpty)
        #expect(answer == "Plain answer text.")
        #expect(gate.flushRemainder() == "Plain answer text.")
    }

    @Test("answer callback is not invoked for thinking-only turns")
    func thinkOnlyNoAnswer() {
        var gate = ThinkStreamGate()
        var answerFired = false
        let live = gate.feed("<think>just thinking</think>", onAnswerToken: { _ in answerFired = true })
        #expect(live == "<think>just thinking</think>")
        #expect(!answerFired)
        #expect(gate.flushRemainder().isEmpty)
    }

    @Test("answer tokens after a split close tag are streamed")
    func answerAfterSplitClose() {
        var (live, answer, gate) = feedAllWithAnswer(["<think>p", "lan</th", "ink>It's done."])
        #expect(live == "<think>plan</think>")
        #expect(answer == "It's done.")
        #expect(gate.flushRemainder() == "It's done.")
    }

    @Test("full answer in one chunk (like StatelessToolTurnSession)")
    func fullAnswerOneChunk() {
        var (live, answer, gate) = feedAllWithAnswer(["<think>checking the weather</think>It's sunny."])
        #expect(live == "<think>checking the weather</think>")
        #expect(answer == "It's sunny.")
        #expect(gate.flushRemainder() == "It's sunny.")
    }

    // MARK: - Pre-opened template (Qwen3.5)

    @Test("pre-opened template: the synthetic opener is token zero; reasoning streams live to the lone </think>")
    func preOpenedStreamsLiveFromTokenZero() {
        // The model never emits `<think>` (its template already did); the
        // session prepends it. Everything up to the lone close is reasoning.
        var (live, answer, gate) = feedAllWithAnswer([
            "<think>", "Let me", " check", " the time", "</think>", "It's", " 3pm.",
        ])
        #expect(live == "<think>Let me check the time</think>")
        #expect(answer == "It's 3pm.")
        #expect(gate.flushRemainder() == "It's 3pm.")
    }

    @Test("pre-opened template, reasoning-only turn: no answer token fires, the remainder is empty")
    func preOpenedReasoningOnlyFiresNoAnswer() {
        var (live, answer, gate) = feedAllWithAnswer(["<think>", "only", " thinking", "</think>"])
        #expect(live == "<think>only thinking</think>")
        #expect(answer.isEmpty)
        #expect(gate.flushRemainder().isEmpty)
    }

    @Test("pre-opened template, thinking off: no opener is yielded; a plain turn streams to the answer")
    func preOpenedThinkingOffIsPlain() {
        // `toolTurnThinkingDecision(turnThinking: false, …).prefixNeeded` is
        // false, so the session yields no opener; the template closed the
        // block itself and the model emits no tags at all.
        var (live, answer, gate) = feedAllWithAnswer(["It's", " 3pm."])
        #expect(live.isEmpty)
        #expect(answer == "It's 3pm.")
        #expect(gate.flushRemainder() == "It's 3pm.")
    }

    @Test("a model re-emitting <think> after the synthetic opener doubles the LIVE tag only, never the answer")
    func redundantModelOpenerNeverReachesAnswer() {
        // Unreachable for a pre-opening template (the opener is in its prompt),
        // pinned so the safety property is explicit: the double lands in the
        // reasoning disclosure, never the bubble, and the final text is
        // deduped by normaliseThinkPrefix's hasPrefix guard.
        var (live, answer, gate) = feedAllWithAnswer(["<think>", "<think>", "plan", "</think>", "done"])
        #expect(live == "<think><think>plan</think>")
        #expect(answer == "done")
        #expect(gate.flushRemainder() == "done")
    }
}
