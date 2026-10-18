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
//  argv, never `defaults write` (macOS 27 keeps the sandboxed app out of it):
//  `M1K3 -thinkBudgetTokens 1024 [-thinkBudgetTransition close|qwen]`. Off when absent.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-18, Confidence 0.75, Prior: none (new file).
//  Open: an eval arm until it beats the character cut on the hard traps; whether a 4B model answers
//  well from a thought cut short is exactly what the arm measures. Qwen's guidance: budgets above 1,024.
//  Review: Kev + claude-opus-5-5, 2026-10-18 — `NoWait`, a second arm (`-thinkWaitPenalty P`) from a Reddit tip
//  Kev passed on: push "Wait" / "Hmm" / "Alternatively" down while thinking, so the thought stops re-opening an
//  answer it already has. Confidence 0.6: re-checks are also how a model catches a trick question.

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

    /// The arm argv asked for, or nil (the shipping default: no budget).
    public static func request(from defaults: UserDefaults) -> Request? {
        let tokens = defaults.integer(forKey: tokensKey)
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

    /// The responder's character cut while a token budget is in force: none, since the forced close
    /// bounds the thought and a 4,000-character cut (about 1,000 tokens) would race it. nil: the
    /// responder's own default.
    public static func characterCap(for request: Request?) -> Int? {
        request == nil ? nil : .max
    }
}

public extension ThinkBudget {
    /// NoWait (Wang et al., "Wait, We Don't Need to 'Wait'!", Findings of EMNLP 2025, arXiv 2506.08343): subtract a
    /// penalty from the self-reflection openers' logits while the model thinks. The paper reports thoughts 27–51%
    /// shorter with accuracy mostly held, but its Table 6 is mixed for Qwen3-4B (AMC 2023 93.8 → 95.5, AIME 2025
    /// 70.0 → 56.7) and it finds distilled models underthink without the re-checks, so the arm measures it on our
    /// traps rather than trusting the average.
    ///
    /// argv: `M1K3 -thinkWaitPenalty 100` (100 bans the openers; 3–5 nudges them). Off when absent. It shapes the
    /// thought but doesn't bound it, so the character cut stays unless `-thinkBudgetTokens` is also set. Like the
    /// budget it rides the plain turn only: a thought on the tool session (MLXToolCalling) is not penalised.
    enum NoWait {
        /// The argv key for the penalty, subtracted from the openers' logits.
        public static let penaltyKey = "thinkWaitPenalty"
        /// The openers, capitalised. The paper's longer list (but, now, check, again…) also cuts plain sentences.
        public static let words = ["Wait", "Hmm", "Alternatively"]

        /// Every spelling a tokenizer may hold as one token: either case, starting a line or after a space.
        public static var spellings: [String] {
            words.flatMap { word in [word, word.lowercased()].flatMap { [$0, " " + $0] } }
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
