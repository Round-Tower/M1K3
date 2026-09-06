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
//  Review: Kev + claude-fable-5.1, 2026-09-06 — pocket shares Mini's budget (PR #234 review 2); measured on pocket
//  before it ever widens. Confidence now 0.85.
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

    /// The ceiling for a SPOKEN turn, on any tier.
    ///
    /// Two independent reasons, and the second is the one that makes this a
    /// design decision rather than a latency hack:
    ///
    /// 1. **Prefill is what a voice user waits for.** Measured on Kev's Mac
    ///    (Lil resident, persona prefix warm, live agent path): prompts of 822
    ///    and 1401 tokens prefilled in 2052 ms and 3045 ms — a marginal
    ///    **1.71 ms per prompt token**, against a decode of ~61 tok/s. Voice
    ///    mode speaks at the first SENTENCE, so decode barely registers in
    ///    time-to-first-audio while prefill is paid in full before a single
    ///    token exists. Trimming 1100 → 400 takes ~1.2 s off every spoken turn.
    /// 2. **A spoken answer cannot spend that grounding anyway.** Nobody reads
    ///    seven document chunks aloud. The typed budget is sized for an answer
    ///    the reader can scan and re-read; a spoken one is a few sentences.
    ///
    /// Deliberately NOT done here: changing the TOOL palette for spoken turns.
    /// The palette is part of the persona-prefix KV cache key, so a mode-
    /// specific palette costs a full prefix rebuild — measured at **6.2 s** on
    /// Lil when the self-query gate's smaller palette missed the cache
    /// (2026-08-13). Tune the grounding, never the palette.
    public static let spokenTokenBudget = 400

    /// The grounding token ceiling for `tier`. The MLX tiers keep
    /// `GroundingBudget.defaultTokenBudget` byte-for-byte — that figure is the
    /// output of PR #65's on-device instrument and this policy is not licence
    /// to re-tune it from an armchair.
    ///
    /// `spoken` can only ever TIGHTEN the result (`min`), never widen it: this
    /// policy's whole direction of failure is toward the smaller budget, and a
    /// mode flag must not be able to reverse that for a tier.
    ///
    /// No tier is exempt, INCLUDING Mini — its 600 trims to 400 like the rest.
    /// Both reasons for the spoken cap apply to Mini at least as hard as to the
    /// others: nobody reads seven chunks aloud whichever brain read them, and
    /// Mini has the least window to spend in the first place.
    public static func tokens(for tier: BrainTier?, spoken: Bool = false) -> Int {
        // nil is an unresolvable persisted brain string. Fail small, matching
        // HistoryBudgetPolicy's nil guard: the cost of being wrong is asymmetric.
        let typed: Int
        // pocket (LFM2.5-1.2B, the non-AFM Mini) takes Mini's budget: a 1.2B with
        // an 8k window, never measured with the 1100-token MLX default — its
        // grounded-Q cell was 6/16 on PR #234's eval. Fail small until measured.
        if let tier, tier != .mini, tier != .pocket {
            typed = GroundingBudget.defaultTokenBudget
        } else {
            typed = miniTokenBudget
        }
        return spoken ? min(typed, spokenTokenBudget) : typed
    }
}
