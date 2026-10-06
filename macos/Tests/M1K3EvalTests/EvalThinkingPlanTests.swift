//
//  EvalThinkingPlanTests.swift
//  M1K3EvalTests
//
//  How a ChatEval brain thinks. The default must be production's shape for
//  the tier — the 2026-10-06 shootout let Qwen3.5 think on every bare turn
//  (14 empty answers) while the app's Lil thinks on ~3 of ~90 fixtures.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-06, Confidence 0.85, Prior: none (new
//  file; GEMMA_1_1_PLAN critical pass, item 3).

@testable import M1K3Eval
import M1K3Inference
import Testing

struct EvalThinkingPlanTests {
    @Test("tier mode mirrors production: speed tiers don't think by default, Big does")
    func tierModeMirrorsProduction() {
        let lil = EvalThinkingPlan(tier: .lil, mode: .tier)
        #expect(lil.bareThinks == false)
        #expect(lil.liveFastByDefault == true)
        #expect(lil.liveForced == nil, "the live arm runs production Auto")

        let big = EvalThinkingPlan(tier: .big, mode: .tier)
        #expect(big.bareThinks == true)
        #expect(big.liveFastByDefault == false)
        #expect(big.liveForced == nil)

        #expect(EvalThinkingPlan(tier: .mini, mode: .tier).liveFastByDefault == BrainTier.mini.prefersFastThinking)
    }

    @Test("always and fast force every arm the same way, whatever the tier")
    func forcedModes() {
        for tier in BrainTier.allCases {
            let always = EvalThinkingPlan(tier: tier, mode: .always)
            #expect(always.bareThinks && always.liveForced == true)
            let fast = EvalThinkingPlan(tier: tier, mode: .fast)
            #expect(!fast.bareThinks && fast.liveForced == false)
        }
    }

    @Test("the env value parses; anything else falls back to tier, never silently to always")
    func parsesEnvValue() {
        #expect(EvalThinkingMode(envValue: nil) == .tier)
        #expect(EvalThinkingMode(envValue: "always") == .always)
        #expect(EvalThinkingMode(envValue: " FAST ") == .fast)
        #expect(EvalThinkingMode(envValue: "on") == .tier)
    }
}
