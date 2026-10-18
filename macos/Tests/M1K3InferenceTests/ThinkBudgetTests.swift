//
//  ThinkBudgetTests.swift
//  M1K3InferenceTests
//
//  Budget forcing, the A/B arm (2026-10-18): Lil thinks 2,500–4,500 tokens before answering a sum,
//  and the 4,000-character cut throws the thought away and asks again. `-thinkBudgetTokens N` makes
//  the provider force `</think>` at N tokens instead, in the same generation, so the answer is built
//  on the thought. Off unless asked for; the arm decides whether it ships.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-18, Confidence 0.8, Prior: none (new file).
//  Review: Kev + claude-opus-5-5, 2026-10-18 — the NoWait arm (`-thinkWaitPenalty P`): argv parsing, the
//  spellings it pushes down, and that it only touches a thought. Confidence 0.8.

import Foundation
@testable import M1K3Inference
import Testing

struct ThinkBudgetTests {
    /// A private defaults domain holding what argv would: every value a string.
    private func defaults(_ values: [String: String]) -> UserDefaults {
        let suite = "ThinkBudgetTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        for (key, value) in values {
            defaults.set(value, forKey: key)
        }
        return defaults
    }

    @Test("off unless argv asks: no key, zero or a negative is no budget")
    func offByDefault() {
        #expect(ThinkBudget.request(from: defaults([:])) == nil)
        #expect(ThinkBudget.request(from: defaults(["thinkBudgetTokens": "0"])) == nil)
        #expect(ThinkBudget.request(from: defaults(["thinkBudgetTokens": "-5"])) == nil)
        #expect(ThinkBudget.request(from: defaults(["thinkBudgetTokens": "lots"])) == nil)
    }

    @Test("argv's string value is read as a token count, closing plainly unless told otherwise")
    func readsArgv() {
        #expect(ThinkBudget.request(from: defaults(["thinkBudgetTokens": "1024"]))
            == ThinkBudget.Request(tokens: 1024, transition: .close))
        #expect(ThinkBudget.request(from: defaults(["thinkBudgetTokens": "2048", "thinkBudgetTransition": "qwen"]))
            == ThinkBudget.Request(tokens: 2048, transition: .qwen))
        #expect(ThinkBudget.request(from: defaults(["thinkBudgetTokens": "1024", "thinkBudgetTransition": "nope"]))
            == ThinkBudget.Request(tokens: 1024, transition: .close))
    }

    @Test("a budget applies only to a generation that opens thinking")
    func onlyWhileThinking() {
        let request = ThinkBudget.Request(tokens: 1024, transition: .close)
        #expect(ThinkBudget.tokens(for: request, maxTokens: 4096, preOpenedThinking: true) == 1024)
        #expect(ThinkBudget.tokens(for: request, maxTokens: 4096, preOpenedThinking: false) == nil)
        #expect(ThinkBudget.tokens(for: nil, maxTokens: 4096, preOpenedThinking: true) == nil)
    }

    @Test("the budget leaves the turn's token cap room for the close and an answer")
    func clampsToTheCap() {
        let huge = ThinkBudget.Request(tokens: 100_000, transition: .close)
        let room = 4096 - ThinkBudget.answerReserve - ThinkBudget.protocolHeadroom
        #expect(ThinkBudget.tokens(for: huge, maxTokens: 4096, preOpenedThinking: true) == room)
        // Big's rotating tier runs a 2,048 cap; a 2,048 budget must shrink to fit it.
        let twoK = ThinkBudget.Request(tokens: 2048, transition: .close)
        #expect(ThinkBudget.tokens(for: twoK, maxTokens: 2048, preOpenedThinking: true)
            == 2048 - ThinkBudget.answerReserve - ThinkBudget.protocolHeadroom)
        // A cap with no room for a budget at all: no budget, never a negative one.
        #expect(ThinkBudget.tokens(for: twoK, maxTokens: 512, preOpenedThinking: true) == nil)
    }

    @Test("the transitions: a bare close, or Qwen's own hand-off line before it")
    func transitions() {
        #expect(ThinkBudget.Transition.close.beforeClose == "\n")
        #expect(ThinkBudget.Transition.close.afterClose == "\n\n")
        #expect(ThinkBudget.Transition.qwen.beforeClose.contains("Considering the limited time by the user"))
        #expect(ThinkBudget.Transition.qwen.afterClose == "\n\n")
        for transition in ThinkBudget.Transition.allCases {
            #expect(!transition.beforeClose.contains("</think>"), "the close tag is the protocol's, added once")
        }
    }

    @Test("the character cut stands aside while a token budget closes the thought")
    func characterCap() {
        #expect(ThinkBudget.characterCap(for: nil) == nil, "nil: the responder's own default")
        #expect(ThinkBudget.characterCap(for: ThinkBudget.Request(tokens: 1024, transition: .close)) == .max)
    }

    @Test("NoWait is off unless argv asks: no key, zero, a negative or junk is no penalty")
    func noWaitOffByDefault() {
        #expect(ThinkBudget.NoWait.penalty(from: defaults([:])) == nil)
        #expect(ThinkBudget.NoWait.penalty(from: defaults(["thinkWaitPenalty": "0"])) == nil)
        #expect(ThinkBudget.NoWait.penalty(from: defaults(["thinkWaitPenalty": "-3"])) == nil)
        #expect(ThinkBudget.NoWait.penalty(from: defaults(["thinkWaitPenalty": "lots"])) == nil)
        #expect(ThinkBudget.NoWait.penalty(from: defaults(["thinkWaitPenalty": "1e-50"])) == nil, "zero as a Float")
    }

    @Test("NoWait reads argv's string as a logit penalty and applies it only inside a thought")
    func noWaitReadsArgv() {
        #expect(ThinkBudget.NoWait.penalty(from: defaults(["thinkWaitPenalty": "100"])) == 100)
        #expect(ThinkBudget.NoWait.penalty(from: defaults(["thinkWaitPenalty": "2.5"])) == 2.5)
        #expect(ThinkBudget.NoWait.penalty(for: 5, preOpenedThinking: true) == 5)
        #expect(ThinkBudget.NoWait.penalty(for: 5, preOpenedThinking: false) == nil)
        #expect(ThinkBudget.NoWait.penalty(for: nil, preOpenedThinking: true) == nil)
    }

    @Test("NoWait's spellings: each opener in either case, starting a line or after a space, once")
    func noWaitSpellings() {
        let spellings = ThinkBudget.NoWait.spellings
        for word in ["Wait", "wait", "Hmm", "hmm", "Alternatively", "alternatively"] {
            #expect(spellings.contains(word))
            #expect(spellings.contains(" " + word))
        }
        #expect(Set(spellings).count == spellings.count)
        #expect(spellings.count == ThinkBudget.NoWait.words.count * 4)
    }
}
