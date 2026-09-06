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

    // MARK: - Spoken turns (2026-08-13)

    @Test("a spoken turn gets a tighter grounding budget than a typed one")
    func spokenIsTighter() {
        // Measured on Kev's Mac, Lil resident, persona prefix warm, live agent
        // path over MCP:
        //     prompt  822 tok → prefill 2052 ms
        //     prompt 1401 tok → prefill 3045 ms
        //     marginal = 993 ms / 579 tok = 1.71 ms per prompt token
        // Prefill is paid IN FULL before the first token exists, and voice mode
        // speaks at the first sentence — so every grounding token is 1.71 ms
        // added directly to time-to-first-audio, the number the user feels.
        #expect(GroundingBudgetPolicy.tokens(for: .lil, spoken: true)
            < GroundingBudgetPolicy.tokens(for: .lil))
        #expect(GroundingBudgetPolicy.tokens(for: .big, spoken: true)
            < GroundingBudgetPolicy.tokens(for: .big))
    }

    @Test("the typed path is byte-identical — this only changes spoken turns")
    func typedPathUnchanged() {
        for tier in BrainTier.allCases {
            #expect(GroundingBudgetPolicy.tokens(for: tier, spoken: false)
                == GroundingBudgetPolicy.tokens(for: tier))
        }
    }

    @Test("spoken never RAISES a tier's budget — it can only tighten")
    func spokenOnlyTightens() {
        // The invariant, not the arithmetic: whatever the constants are today, a
        // tier already tighter than the spoken ceiling must keep its own number.
        // This policy's whole direction of failure is toward the smaller budget
        // and a mode flag must not be able to reverse it. Which tier is currently
        // on which side of the ceiling is `miniIsNotExemptWhenSpoken`'s job — a
        // distinction this `<=` cannot make, which is how the doc comment came to
        // claim the opposite of the behaviour for a whole PR review cycle.
        for tier in BrainTier.allCases {
            #expect(GroundingBudgetPolicy.tokens(for: tier, spoken: true)
                <= GroundingBudgetPolicy.tokens(for: tier))
        }
        #expect(GroundingBudgetPolicy.tokens(for: nil, spoken: true)
            <= GroundingBudgetPolicy.tokens(for: nil))
    }

    @Test("no tier is exempt from the spoken trim — including Mini")
    func miniIsNotExemptWhenSpoken() {
        // `spokenOnlyTightens` uses `<=`, which passes whether Mini is left at
        // 600 or trimmed to 400 — so the contract lived only in a doc comment,
        // and that comment was backwards (review catch, PR #120). Both reasons
        // for the spoken cap apply to Mini hardest: nobody reads seven chunks
        // aloud whichever brain read them, and Mini has the least window.
        #expect(GroundingBudgetPolicy.tokens(for: .mini, spoken: true)
            == GroundingBudgetPolicy.spokenTokenBudget)
        #expect(GroundingBudgetPolicy.tokens(for: nil, spoken: true)
            == GroundingBudgetPolicy.spokenTokenBudget)
    }

    @Test("a spoken turn still fits a real retrieved chunk — this is a trim, not a mute")
    func spokenStillGrounds() {
        // Live grounding on Kev's store ran ~290 tokens per kept unit (3 units =
        // 872 tokens, measured 2026-08-13). A budget under one unit would round
        // down to no grounding at all and quietly turn voice mode into an
        // ungrounded assistant — which is not a latency win, it is a different
        // product.
        let measuredUnitTokens = 290
        #expect(GroundingBudgetPolicy.tokens(for: .lil, spoken: true) >= measuredUnitTokens)
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

    @Test("pocket (LFM2 as the non-AFM Mini) takes Mini's budget, spoken cap included")
    func pocketTakesMiniBudget() {
        #expect(GroundingBudgetPolicy.tokens(for: .pocket) == GroundingBudgetPolicy.tokens(for: .mini))
        #expect(GroundingBudgetPolicy.tokens(for: .pocket, spoken: true) == GroundingBudgetPolicy.tokens(for: .mini, spoken: true))
    }
}
