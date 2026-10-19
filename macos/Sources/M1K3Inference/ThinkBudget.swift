//
//  ThinkBudget.swift
//  M1K3Inference
//
//  Budget forcing, the A/B arm (2026-10-18). Lil (Qwen3.5-4B) thinks 2,500–4,500 tokens before
//  answering even a sum: honest deliberation, not a loop (1 run in 28 looped). The shipping cap
//  (`ThinkingPolicy.thinkingBudgetCharacters`) cuts the stream at 4,000 characters and asks again
//  with thinking off, so the thought is shown and then thrown away. Here the provider forces
//  `</think>` at a token budget inside the same generation (mlx-swift-lm's `ThinkingBudgetProcessor`),
//  so the answer is written on top of the thought, on the same cache.
//
//  Lil (its exact id) forces at 1,024 tokens by default. argv, never `defaults write` (macOS 27 keeps the
//  sandboxed app out of it), overrides for any brain: `M1K3 -thinkBudgetTokens 2048
//  [-thinkBudgetTransition close|qwen]`; `-thinkBudgetTokens 0` is off. While a brain forces, the
//  responder's character cut stands back to a net (`characterCap(forTokens:)`), read through
//  `ThinkBudgetForcing` so every shell gets it.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-18, Confidence 0.75, Prior: none (new file).
//  Review: Kev + claude-opus-5-5, 2026-10-18 — `NoWait`, a second arm (`-thinkWaitPenalty P`) from a Reddit tip
//  Kev passed on: push "Wait" / "Hmm" / "Alternatively" down while thinking, so the thought stops re-opening an
//  answer it already has. Confidence 0.6: re-checks are also how a model catches a trick question.
//  Review: Kev + claude-opus-5-5, 2026-10-19 — forcing ships for Lil, and the Open (an arm until it beats the
//  cut) closes: on the hard traps, number words credited, 1,024 tokens scored 36/38 at a 56 s median against
//  the cut's 29/38 at 60 s and no limit's 33/38 at 175 s (docs/evals/2026-10-18-lil-thinking.md). By exact id,
//  so an audition with a pre-opening template (Qwen3.8, Bonsai-27B) isn't budgeted untested; argv still
//  reaches any brain, and 0 is off. The cut becomes a net at 8 characters a token (8,192 at 1,024; the
//  longest forced thought measured 4,755), decided from the brain through `ThinkBudgetForcing`, so the iOS
//  shell's 4,000 can't race the close. NoWait's words take argv (`-thinkWaitWords`; `paper` is the paper's
//  seventeen, "but" and "check" among them, from Kev's guess). Confidence 0.8: challenger's narrowed ship.

import Foundation

public enum ThinkBudget {
    /// The argv key for the budget, in tokens.
    public static let tokensKey = "thinkBudgetTokens"
    /// The argv key for the forced transition (`close` or `qwen`).
    public static let transitionKey = "thinkBudgetTransition"
    /// Tokens kept for the answer after the forced close.
    public static let answerReserve = 768
    /// Slack for the forced transition and a part-finished Unicode scalar (the qwen line is ~25 tokens).
    public static let protocolHeadroom = 64

    /// What the provider forces when the budget runs out, around the protocol's own `</think>`.
    public enum Transition: String, Sendable, CaseIterable {
        /// Close the thought and nothing more.
        case close
        /// Qwen's documented hand-off line, then close (Qwen3's budget-forcing recipe).
        case qwen

        public var beforeClose: String {
            switch self {
            case .close: "\n"
            case .qwen:
                "\n\nConsidering the limited time by the user, I have to give the solution based on the thinking directly now.\n"
            }
        }

        public var afterClose: String {
            "\n\n"
        }
    }

    public struct Request: Equatable, Sendable {
        public let tokens: Int
        public let transition: Transition

        public init(tokens: Int, transition: Transition) {
            self.tokens = tokens
            self.transition = transition
        }
    }

    /// The brains that force by default, by exact id (lowercased), with their budgets in tokens. Lil only:
    /// a family match would budget an audition (Qwen3.8, Bonsai-27B pre-open `<think>` too) nobody measured.
    public static let shippingBudgets = ["mlx-community/qwen3.5-4b-mlx-4bit": 1024]

    /// The budget for `modelID`: argv's when it names one (any brain; zero, a negative or junk is off), else the
    /// brain's shipping budget, else nil.
    public static func request(from defaults: UserDefaults, modelID: String) -> Request? {
        // object(forKey:) first: argv's `0` has to read as off, not as absent.
        let tokens = defaults.object(forKey: tokensKey) != nil
            ? defaults.integer(forKey: tokensKey)
            : shippingBudgets[modelID.lowercased()] ?? 0
        guard tokens > 0 else { return nil }
        let transition = defaults.string(forKey: transitionKey).flatMap(Transition.init(rawValue:)) ?? .close
        return Request(tokens: tokens, transition: transition)
    }

    /// The budget for one generation: only when it opens a thought (`preOpenedThinking`: thinking on
    /// and a template that pre-opens `<think>`), and never more than `maxTokens` can hold beside
    /// the close and the answer reserve. nil: generate unbudgeted.
    public static func tokens(for request: Request?, maxTokens: Int, preOpenedThinking: Bool) -> Int? {
        guard let request, preOpenedThinking else { return nil }
        let room = maxTokens - answerReserve - protocolHeadroom
        guard room > 0 else { return nil }
        return min(request.tokens, room)
    }

    /// Characters a token the cut allows a forcing brain's thought: Lil's thoughts run about 3.8 a token, so 8
    /// is a net for a runaway (a close that never lands), never a race with the close.
    public static let netCharactersPerToken = 8

    /// The responder's character cut while a brain forces its close at `tokens`: a net above the budget, since
    /// the forced close bounds the thought and a 4,000-character cut (about 1,000 tokens) would race it.
    public static func characterCap(forTokens tokens: Int) -> Int {
        tokens * netCharactersPerToken
    }
}

/// A brain that closes its own thought at a token budget (budget forcing). The responder reads it per turn to
/// stand its character cut back to a net, `ThinkBudget.characterCap(forTokens:)`. Every façade forwards it,
/// or the cut races the close in production while the eval, holding the bare provider, looks fine.
public protocol ThinkBudgetForcing: InferenceProvider {
    /// The budget this brain forces on a generation that thinks, in tokens; nil when it forces none (no budget,
    /// a template that doesn't pre-open `<think>`, or a token cap with no room for one).
    var forcedThinkingTokens: Int? { get }
}

public extension ThinkBudget {
    /// NoWait (Wang et al., "Wait, We Don't Need to 'Wait'!", Findings of EMNLP 2025, arXiv 2506.08343): subtract a
    /// penalty from the self-reflection openers' logits while the model thinks. The paper reports thoughts 27–51%
    /// shorter with accuracy mostly held, but its Table 6 is mixed for Qwen3-4B (AMC 2023 93.8 → 95.5, AIME 2025
    /// 70.0 → 56.7) and it finds distilled models underthink without the re-checks, so the arm measures it on our
    /// traps rather than trusting the average.
    ///
    /// argv: `M1K3 -thinkWaitPenalty 100 [-thinkWaitWords Wait,Hmm,But|paper]` (100 bans the words; 3–5 nudges
    /// them). Off when absent. It shapes the thought but doesn't bound it: the budget, where the brain forces one,
    /// still does. Like the budget it rides the plain turn only: the tool session (MLXToolCalling) isn't penalised.
    enum NoWait {
        /// The argv key for the penalty, subtracted from the openers' logits.
        public static let penaltyKey = "thinkWaitPenalty"
        /// The argv key for the words: a comma list, or `paper` for `paperWords`.
        public static let wordsKey = "thinkWaitWords"
        /// The openers, capitalised. The paper's longer list also cuts plain sentences ("but", "now", "any").
        public static let defaultWords = ["Wait", "Hmm", "Alternatively"]
        /// The paper's list (§3.1), capitalised. It also bans every vocabulary token containing a word; this
        /// arm bans each word's single-token spellings only.
        public static let paperWords = [
            "Wait", "Alternatively", "Hmm", "But", "However", "Alternative", "Another", "Check", "Double-check",
            "Oh", "Maybe", "Verify", "Other", "Again", "Now", "Ah", "Any",
        ]

        /// The words argv named, `paperWords` for `paper`, else `defaultWords`.
        public static func words(from defaults: UserDefaults) -> [String] {
            guard let raw = defaults.string(forKey: wordsKey) else { return defaultWords }
            if raw.trimmingCharacters(in: .whitespaces).lowercased() == "paper" { return paperWords }
            let words = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return words.isEmpty ? defaultWords : words
        }

        /// Every spelling of `words` a tokenizer may hold as one token: capitalised or lowercase, starting a line or
        /// after a space, each once.
        public static func spellings(of words: [String]) -> [String] {
            var seen = Set<String>()
            return words.flatMap { word in
                [word.prefix(1).uppercased() + word.dropFirst(), word.lowercased()].flatMap { [$0, " " + $0] }
            }.filter { seen.insert($0).inserted }
        }

        /// The penalty argv asked for, or nil (the shipping default: none).
        public static func penalty(from defaults: UserDefaults) -> Float? {
            // Narrowed before the test: a Double too small for a Float would read as on and subtract nothing.
            let penalty = Float(defaults.double(forKey: penaltyKey))
            return penalty > 0 ? penalty : nil
        }

        /// The penalty for one generation: only when it opens a thought, like the token budget.
        public static func penalty(for requested: Float?, preOpenedThinking: Bool) -> Float? {
            preOpenedThinking ? requested : nil
        }
    }
}
