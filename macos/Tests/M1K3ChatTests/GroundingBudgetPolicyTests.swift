//
//  GroundingBudgetPolicyTests.swift
//  M1K3ChatTests
//
//  `GroundingBudget.defaultTokenBudget = 1100` was DERIVED — its own header
//  says so — from Big's 3000-token reserve inside an 8192-token window. It was
//  then applied unchanged to every tier, including Mini's 4096-token window,
//  where the same figure is 27% of everything the model has rather than 13%.
//
//  PR #101 stopped the cap failing OPEN on Mini (it used to stand down entirely
//  when the provider had no tokenizer). That fixed whether the cap ran; it did
//  not fix what the cap was set to. This is that second half.
//
//  The arithmetic these numbers answer to, for a Mini ReAct turn AFTER the
//  persona duplication is removed (~4.4 chars/token, measured PR #65):
//
//      AFM session instructions (persona)   ~890
//      history replay (3000 chars @ 3.5)    ~857
//      .react RULES + tool routing          ~360
//      tool descriptions                    ~360
//      ReAct scaffold + goal + context line ~105
//      -------------------------------------------
//      fixed                                ~2572  of 4096
//
//  Leaving ~1520 to split between grounding and the ANSWER. 1100 for grounding
//  would leave ~420 tokens of output — under the length bands #111 already
//  records Mini overshooting. 600 leaves ~920, which is an answer.
//
//  Signed: Kev + claude-opus-5, 2026-08-09, Confidence 0.85 (the component
//  figures are measured or documented upstream; the split between grounding and
//  output is a judgement call, and the on-device re-measure is owed).
//  Prior: Unknown.
//

@testable import M1K3Chat
import M1K3Inference
import M1K3Knowledge
import Testing

struct GroundingBudgetPolicyTests {
    @Test("Mini gets a smaller grounding budget than the MLX-derived default")
    func miniIsSmaller() {
        let mini = GroundingBudgetPolicy.tokens(for: .mini)
        #expect(mini < GroundingBudget.defaultTokenBudget)
    }

    @Test("the MLX tiers keep the measured default exactly — this changes nothing for them")
    func mlxTiersUnchanged() {
        // Big's 1100 is the figure PR #65's on-device instrument justified. No
        // part of this policy is licence to re-tune it from an armchair.
        #expect(GroundingBudgetPolicy.tokens(for: .big) == GroundingBudget.defaultTokenBudget)
        #expect(GroundingBudgetPolicy.tokens(for: .lil) == GroundingBudget.defaultTokenBudget)
    }

    @Test("an unknown tier falls back to the conservative Mini budget, not the widest")
    func unknownTierIsConservative() {
        // Same guard direction as HistoryBudgetPolicy's nil case: a persisted
        // brain string we can't resolve must not be handed the widest budget on
        // the ladder. Under-filling a large window wastes a little grounding;
        // over-filling a small one silently rotates the prompt head out.
        #expect(GroundingBudgetPolicy.tokens(for: nil) == GroundingBudgetPolicy.tokens(for: .mini))
    }

    @Test("Mini's budget leaves real room to answer inside its 4096-token window")
    func miniLeavesOutputRoom() {
        // The whole point: a budget that consumes the window is not a budget.
        // Fixed cost is ~2572 tokens (see this file's header); the answer needs
        // meaningfully more than the ~420 tokens the old default would have left.
        let fixedCost = 2572
        let window = BrainTier.mini.approximateContextTokens
        let outputRoom = window - fixedCost - GroundingBudgetPolicy.tokens(for: .mini)
        #expect(outputRoom > 700, "only \(outputRoom) tokens left to answer in")
    }

    @Test("no tier is given a budget that cannot fit its own window")
    func everyTierFitsItsWindow() {
        for tier in BrainTier.allCases {
            let budget = GroundingBudgetPolicy.tokens(for: tier)
            #expect(budget > 0)
            #expect(
                budget < tier.approximateContextTokens / 2,
                "\(tier) grounding budget is over half its window"
            )
        }
    }
}
