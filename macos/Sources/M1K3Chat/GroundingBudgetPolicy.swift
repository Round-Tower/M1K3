//
//  GroundingBudgetPolicy.swift
//  M1K3Chat
//
//  How many tokens of retrieved grounding a tier can afford.
//
//  `GroundingBudget.defaultTokenBudget = 1100` is a good number that was
//  measured for ONE tier. Its own header records the derivation: Big's 3000-
//  token reserve inside an 8192-token window, minus the measured fixed parts.
//  Applied unchanged to Mini it means something completely different — 27% of
//  a 4096-token window instead of 13% of an 8192 one — on the tier with the
//  least room and the most to lose.
//
//  PR #101 fixed the cap FAILING OPEN on Mini (it stood down entirely when the
//  provider exposed no tokenizer, which was the 2026-08-03 bug). That settled
//  whether the cap ran. This settles what it is set to — the half that was left.
//
//  Same shape as HistoryBudgetPolicy, deliberately: per-tier sizing lives in a
//  pure policy, Mini gets an explicit conservative constant rather than a
//  formula fitted to MLX-sized reserves, and an unresolvable tier fails toward
//  the SMALL budget. Over-filling a small window is silent and severe;
//  under-filling a large one costs a little grounding.
//
//  Signed: Kev + claude-opus-5, 2026-08-09, Confidence 0.85, Prior: Unknown
//  Context: macos/docs/NEXT_SESSION.md #102. The MLX figure is untouched;
//  only Mini moves, and an on-device re-measure of the split is owed.
//

import Foundation
import M1K3Inference
import M1K3Knowledge

public enum GroundingBudgetPolicy {
    /// Mini's grounding ceiling. NOT a scaled-down 1100 — an arithmetic answer.
    /// A Mini ReAct turn's fixed cost, once the persona is no longer sent twice
    /// (see `PersonaCarrying`), is roughly:
    ///
    ///     persona (AFM session instructions)   ~890
    ///     history replay (3000 chars @ 3.5)    ~857
    ///     .react RULES + tool routing          ~360
    ///     tool descriptions                    ~360
    ///     ReAct scaffold + goal + context line ~105
    ///                                        = ~2572 of 4096
    ///
    /// That leaves ~1520 tokens to split between grounding and the ANSWER.
    /// Spending 1100 on grounding leaves ~420 to answer in — below the length
    /// bands #111 already records Mini overshooting, i.e. a budget that starves
    /// the output. 600 leaves ~920, which is an answer with room to breathe.
    ///
    /// A budget that consumes the window is not a budget.
    public static let miniTokenBudget = 600

    /// The grounding token ceiling for `tier`. The MLX tiers keep
    /// `GroundingBudget.defaultTokenBudget` byte-for-byte — that figure is the
    /// output of PR #65's on-device instrument and this policy is not licence
    /// to re-tune it from an armchair.
    public static func tokens(for tier: BrainTier?) -> Int {
        // nil is an unresolvable persisted brain string. Fail small, matching
        // HistoryBudgetPolicy's nil guard: the cost of being wrong is asymmetric.
        guard let tier, tier != .mini else { return miniTokenBudget }
        return GroundingBudget.defaultTokenBudget
    }
}
