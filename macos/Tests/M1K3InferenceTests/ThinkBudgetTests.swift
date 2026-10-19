//
//  ThinkBudgetTests.swift
//  M1K3InferenceTests
//
//  Budget forcing, the A/B arm (2026-10-18): Lil thinks 2,500–4,500 tokens before answering a sum,
//  and the 4,000-character cut throws the thought away and asks again. `-thinkBudgetTokens N` makes
//  the provider force `</think>` at N tokens instead, in the same generation, so the answer is built
//  on the thought. Lil's exact id forces at 1,024 tokens by default (2026-10-19); argv overrides for
//  any brain, and 0 is off.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-18, Confidence 0.8, Prior: none (new file).
//  Review: Kev + claude-opus-5-5, 2026-10-18 — the NoWait arm (`-thinkWaitPenalty P`): argv parsing, the
//  spellings it pushes down, and that it only touches a thought. Confidence 0.8.
//  Review: Kev + claude-opus-5-5, 2026-10-19 — forcing ships for Lil: 1,024 tokens by default for Lil's exact
//  id only, argv overriding for any brain (0 is off), and the character cut a net at 8 per token above it. The
//  NoWait word list takes argv too (`-thinkWaitWords`, or `paper` for the paper's seventeen). Confidence 0.8.
//  Review: same day (pre-push review) — the shipping Lil tier must carry a budget (a Lil swap re-measures and adds
//  its id), the keys are lowercase, the transition reads case-blind, and the audition case is a real folder form.

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

    private let lil = "mlx-community/Qwen3.5-4B-MLX-4bit"

    /// The request for `modelID` with `values` on argv.
    private func request(_ values: [String: String], _ modelID: String) -> ThinkBudget.Request? {
        ThinkBudget.request(from: defaults(values), modelID: modelID)
    }

    @Test("Lil forces at 1,024 tokens by default, closing plainly")
    func lilDefault() {
        #expect(request([:], lil) == ThinkBudget.Request(tokens: 1024, transition: .close))
        #expect(request([:], lil.uppercased()) == ThinkBudget.Request(tokens: 1024, transition: .close), "case-blind")
    }

    @Test("the shipping Lil has a measured budget, under a lowercase key")
    func shippingLilIsBudgeted() throws {
        let tierLil = try #require(BrainTier.lil.mlxModelID)
        #expect(
            request([:], tierLil) != nil,
            "BrainTier.lil is now \(tierLil): measure its forced budget, then add it to ThinkBudget.shippingBudgets"
        )
        for key in ThinkBudget.shippingBudgets.keys {
            #expect(key == key.lowercased(), "lookup lowercases the id, so \(key) would never match")
        }
    }

    @Test("no other brain forces by default: the exact id only, not the family", arguments: [
        "mlx-community/gemma-4-12B-it-4bit", "mlx-community/LFM2.5-1.2B-Instruct-4bit",
        "mlx-community/Qwen3.5-2B-MLX-4bit", "mlx-community/Qwen3.8-27B-4bit", "prism-ml/Ternary-Bonsai-27B",
        // Another org's folder of the same repo: never a suffix match. (A folder at
        // <root>/mlx-community/Qwen3.5-4B-MLX-4bit reports Lil's exact id, and is budgeted on purpose.)
        "lmstudio-community/Qwen3.5-4B-MLX-4bit",
    ])
    func othersOffByDefault(modelID: String) {
        #expect(request([:], modelID) == nil)
    }

    @Test("argv turns it off: zero, a negative or junk is no budget, on Lil too")
    func argvTurnsItOff() {
        for value in ["0", "-5", "lots"] {
            #expect(request(["thinkBudgetTokens": value], lil) == nil, "\(value)")
        }
    }

    @Test("argv's budget wins for any brain, closing plainly unless told otherwise")
    func readsArgv() {
        let gemma = "mlx-community/gemma-4-12B-it-4bit"
        #expect(request(["thinkBudgetTokens": "2048"], gemma) == ThinkBudget.Request(tokens: 2048, transition: .close))
        #expect(request(["thinkBudgetTokens": "2048", "thinkBudgetTransition": "qwen"], lil)
            == ThinkBudget.Request(tokens: 2048, transition: .qwen))
        #expect(request(["thinkBudgetTokens": "1024", "thinkBudgetTransition": "nope"], lil)
            == ThinkBudget.Request(tokens: 1024, transition: .close))
        #expect(request(["thinkBudgetTransition": "qwen"], lil)
            == ThinkBudget.Request(tokens: 1024, transition: .qwen), "the transition applies to the default too")
        #expect(request(["thinkBudgetTransition": "Qwen"], lil)
            == ThinkBudget.Request(tokens: 1024, transition: .qwen), "case-blind")
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

    /// The forced close bounds the thought, so the cut is only a net: 8 characters a token. At 1,024 that's 8,192,
    /// above the longest forced thought measured (4,755 characters, 2026-10-18/19) and so never racing the close.
    @Test("while a brain forces its close, the character cut is a net at 8 per token above it")
    func characterCap() {
        #expect(ThinkBudget.characterCap(forTokens: 1024) == 8192)
        #expect(ThinkBudget.characterCap(forTokens: 1024) > 4755, "above the longest forced thought")
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
        let spellings = ThinkBudget.NoWait.spellings(of: ThinkBudget.NoWait.defaultWords)
        for word in ["Wait", "wait", "Hmm", "hmm", "Alternatively", "alternatively"] {
            #expect(spellings.contains(word))
            #expect(spellings.contains(" " + word))
        }
        #expect(Set(spellings).count == spellings.count)
        #expect(spellings.count == ThinkBudget.NoWait.defaultWords.count * 4)
        #expect(ThinkBudget.NoWait.spellings(of: ["but", "But"]).count == 4, "a word given twice is spelled once")
    }

    @Test("NoWait's words: the three openers unless argv names its own, or `paper` for the paper's seventeen")
    func noWaitWords() {
        #expect(ThinkBudget.NoWait.words(from: defaults([:])) == ["Wait", "Hmm", "Alternatively"])
        #expect(ThinkBudget.NoWait.words(from: defaults(["thinkWaitWords": "Wait, Hmm,Alternatively,But , Check,,"]))
            == ["Wait", "Hmm", "Alternatively", "But", "Check"])
        let paper = ThinkBudget.NoWait.words(from: defaults(["thinkWaitWords": "paper"]))
        #expect(paper.count == 17)
        #expect(paper.contains("But") && paper.contains("Check") && paper.contains("Double-check"))
        #expect(ThinkBudget.NoWait.words(from: defaults(["thinkWaitWords": " , "])) == ThinkBudget.NoWait.defaultWords)
    }
}
