//
//  ThinkPhaseTests.swift
//  M1K3EvalTests
//
//  Signed: Kev + claude-fable-5.1, 2026-10-10, Confidence 0.85, Prior: none (new file).
//  Review: Kev + claude-opus-5-5, 2026-10-18 — the metacognition arms (reread, trap, working, budget) parse
//  and keep the "Then answer normally" contract; two of them must work on a turn that never thinks.
//  Review: Kev + claude-opus-5-5, 2026-10-18 — the thought itself: `ThinkPhase.thought` and a score that keeps
//  it whole through repeats, notes and JSON (Kev: eval the thinking, not only the answer). Confidence 0.85.

import Foundation
@testable import M1K3Eval
import Testing

struct ThinkPhaseTests {
    @Test("a closed block splits into think and answer characters")
    func closedBlock() {
        let m = ThinkPhase.measure("<think>abc def</think>\nThe answer.")
        #expect(m.thinkChars == 7)
        #expect(m.answerChars == "\nThe answer.".count)
        #expect(!m.unclosed)
    }

    @Test("no block is all answer; an unclosed block is all think from the tag on")
    func noBlockAndUnclosed() {
        #expect(ThinkPhase.measure("Just an answer.") == ThinkPhaseMetrics(thinkChars: 0, answerChars: 15, unclosed: false))
        let m = ThinkPhase.measure("Hi <think>still going")
        #expect(m.thinkChars == "still going".count)
        #expect(m.answerChars == 3)
        #expect(m.unclosed)
    }

    @Test("only the first block is measured; a stray second open counts as answer")
    func onlyFirstBlock() {
        let m = ThinkPhase.measure("<think>x</think>a<think>b")
        #expect(m.thinkChars == 1)
        #expect(m.answerChars == "a<think>b".count)
    }

    @Test("the clock spans first token to first non-blank answer token, nil without a block")
    func clock() {
        var c = ThinkPhaseClock()
        var folded = "<think>"
        c.feed(transcript: folded, at: .seconds(1))
        folded += "thinking…"
        c.feed(transcript: folded, at: .seconds(2))
        #expect(c.thinkMS == nil, "no answer yet")
        folded += "</think>\n"
        c.feed(transcript: folded, at: .seconds(3))
        #expect(c.thinkMS == nil, "whitespace is not an answer")
        folded += "Yes"
        c.feed(transcript: folded, at: .milliseconds(3500))
        #expect(c.thinkMS == 2500)
        c.feed(transcript: folded + "more", at: .seconds(9))
        #expect(c.thinkMS == 2500, "fixed once the answer started")

        var plain = ThinkPhaseClock()
        plain.feed(transcript: "Hello", at: .seconds(1))
        #expect(plain.thinkMS == nil, "nothing was thought")
    }

    @Test("the matrix cell carries ~think tokens only when a trial recorded a block")
    func reportCell() {
        let thought = ChatEvalScore(
            fixtureID: "a", kind: .reasoning, checks: [EvalCheck(name: "non-empty", outcome: .pass)],
            latencyMS: 100, thinkChars: 800, thinkMS: 4000
        )
        let plain = ChatEvalScore(
            fixtureID: "b", kind: .openChat, checks: [EvalCheck(name: "non-empty", outcome: .pass)], latencyMS: 50
        )
        let out = ChatEvalReport.matrix([ChatEvalReport.BrainRun(brainID: "lil", scores: [thought, plain])])
        #expect(out.contains("1/1 100ms ~200tk"), "reasoning: 800 chars ≈ 200 tokens")
        #expect(out.contains("1/1 50ms") && !out.contains("50ms ~"), "open-chat: no block, no suffix")
    }

    @Test("steer arms parse from the env, case-folded; unknown is the baseline")
    func steers() {
        #expect(ThinkSteer(envValue: " Emoji ") == .emoji)
        #expect(ThinkSteer(envValue: nil) == .none)
        #expect(ThinkSteer(envValue: "wild") == .none)
        #expect(ThinkSteer.none.clause == nil)
        for steer in ThinkSteer.allCases where steer != .none {
            #expect(steer.clause?.contains("Then answer normally") == true, Comment(rawValue: steer.rawValue))
        }
    }

    @Test("the metacognition arms parse from the env")
    func metacognitionArms() {
        #expect(ThinkSteer(envValue: "reread") == .reread)
        #expect(ThinkSteer(envValue: "TRAP") == .trap)
        #expect(ThinkSteer(envValue: "working") == .working)
        #expect(ThinkSteer(envValue: "budget") == .budget)
    }

    @Test("reread, trap and working steer a straight answer too, not only a think phase")
    func straightTurnArms() {
        for steer in [ThinkSteer.reread, .trap, .working] {
            let clause = steer.clause ?? ""
            #expect(!clause.hasPrefix("When you reason"), Comment(rawValue: steer.rawValue))
        }
        #expect(ThinkSteer.budget.clause?.hasPrefix("When you reason") == true)
    }

    @Test("the thought is the first block's text: to the close, or to the end when it never closed")
    func thoughtText() {
        #expect(ThinkPhase.thought("<think>abc def</think>\nThe answer.") == "abc def")
        #expect(ThinkPhase.thought("Hi <think>still going") == "still going")
        #expect(ThinkPhase.thought("<think>x</think>a<think>b") == "x")
        #expect(ThinkPhase.thought("Just an answer.") == nil)
    }

    @Test("a score keeps the whole thought through repeats, notes and JSON; no key when nothing was thought")
    func scoreKeepsTheThought() throws {
        let fixture = ChatEvalFixture(id: "t", kind: .reasoning, prompt: "p", expectation: .init())
        let thought = String(repeating: "Wait, let me check that again. ", count: 400)
        let score = ChatEvalScorer.score(
            fixture: fixture, observation: EvalObservation(rawText: "<think>\(thought)</think>\nTwelve.")
        )
        #expect(score.thought == thought, "whole, not excerpted like the answer")
        #expect(score.thinkChars == thought.count)
        let carried = score.withRepeatIndex(1).appending(EvalCheck(name: "note", outcome: .pass))
        #expect(carried.thought == thought)
        let decoded = try JSONDecoder().decode(ChatEvalScore.self, from: JSONEncoder().encode(carried))
        #expect(decoded.thought == thought)

        let plain = ChatEvalScorer.score(fixture: fixture, observation: EvalObservation(rawText: "Twelve."))
        #expect(plain.thought == nil)
        let json = try #require(String(data: JSONEncoder().encode(plain), encoding: .utf8))
        #expect(!json.contains("\"thought\""), "no key: documents from before it read the same")
    }
}
