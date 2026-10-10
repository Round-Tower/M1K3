//
//  ThinkPhaseTests.swift
//  M1K3EvalTests
//
//  Signed: Kev + claude-fable-5.1, 2026-10-10, Confidence 0.85, Prior: none (new file).

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
        c.feed("<think>", at: .seconds(1))
        c.feed("thinking…", at: .seconds(2))
        #expect(c.thinkMS == nil, "no answer yet")
        c.feed("</think>\n", at: .seconds(3))
        #expect(c.thinkMS == nil, "whitespace is not an answer")
        c.feed("Yes", at: .milliseconds(3500))
        #expect(c.thinkMS == 2500)
        c.feed("more", at: .seconds(9))
        #expect(c.thinkMS == 2500, "fixed once the answer started")

        var plain = ThinkPhaseClock()
        plain.feed("Hello", at: .seconds(1))
        #expect(plain.thinkMS == nil, "nothing was thought")
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
}
