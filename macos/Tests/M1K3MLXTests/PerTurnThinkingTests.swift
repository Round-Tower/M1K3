//
//  PerTurnThinkingTests.swift
//  M1K3MLXTests
//
//  The turn's thinking decision reaches EVERY generation of the turn (#555):
//  `InferenceIntent.thinking` overrides the provider's construction-time flag
//  for the template switch and the synthetic `<think>` opener alike. Before,
//  only the tool-call session took the per-turn flag; the plain route and the
//  post-tool synthesis read the construction flag (true in the app) and thought
//  to the 4,096-token cap on Auto.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-11
//  Prior: none
//  Confidence: 0.85 — pure flag plumbing on a Qwen3.5 provider that is never loaded.
//  Review: Kev + claude-opus-5-5, 2026-10-19 — `forcedThinkingTokens`: Lil reports its 1,024-token budget to the
//  responder's cut whatever the build's thinking flag; Big's template never pre-opens a thought, so it reports
//  none. Confidence 0.85.
//  Review: same day (pre-push review) — the template guard pinned with a budget in hand: argv's budget on a brain
//  whose template opens no thought reports none (through the init's `defaults`), on Lil it reports argv's.
//

import Foundation
import M1K3Inference
@testable import M1K3MLX
import Testing

struct PerTurnThinkingTests {
    private let lil = MLXBrainProvider(modelID: "mlx-community/Qwen3.5-4B-MLX-4bit")

    @Test("no turn decision: the construction flag governs (thinking on by default)")
    func constructionFlagByDefault() {
        #expect(lil.thinkingAdditionalContext == nil)
        #expect(lil.thinkPrefixNeeded)
        let fast = MLXBrainProvider(modelID: "mlx-community/Qwen3.5-4B-MLX-4bit", thinkingEnabled: false)
        #expect(fast.thinkingAdditionalContext?["enable_thinking"] as? Bool == false)
        #expect(!fast.thinkPrefixNeeded)
    }

    @Test("a turn that decided fast switches the template off and drops the opener, on a thinking-on build")
    func turnDecisionFastWins() async {
        await InferenceIntent.withThinking(false) {
            #expect(lil.thinkingAdditionalContext?["enable_thinking"] as? Bool == false)
            #expect(!lil.thinkPrefixNeeded)
        }
        #expect(lil.thinkingAdditionalContext == nil)
    }

    @Test("a turn that decided to think wins over a thinking-off build")
    func turnDecisionThinkWins() async {
        let fast = MLXBrainProvider(modelID: "mlx-community/Qwen3.5-4B-MLX-4bit", thinkingEnabled: false)
        await InferenceIntent.withThinking(true) {
            #expect(fast.thinkingAdditionalContext == nil)
            #expect(fast.thinkPrefixNeeded)
        }
    }

    @Test("a family without the switch ignores the turn decision")
    func noSwitchNoContext() async {
        let gemma = MLXBrainProvider(modelID: "mlx-community/gemma-4-12B-it-4bit")
        await InferenceIntent.withThinking(false) {
            #expect(gemma.thinkingAdditionalContext == nil)
            #expect(!gemma.thinkPrefixNeeded)
        }
    }

    @Test("Lil reports its forced budget to the cut on any build; Big, whose template opens no thought, reports none")
    func forcedThinkingTokens() {
        #expect(lil.forcedThinkingTokens == 1024)
        let fast = MLXBrainProvider(modelID: "mlx-community/Qwen3.5-4B-MLX-4bit", thinkingEnabled: false)
        #expect(fast.forcedThinkingTokens == 1024, "a turn may still decide to think")
        #expect(MLXBrainProvider(modelID: "mlx-community/gemma-4-12B-it-4bit").forcedThinkingTokens == nil)
        // The budget fits the token cap: a cap too small for the close and an answer forces nothing.
        let tight = MLXBrainProvider(modelID: "mlx-community/Qwen3.5-4B-MLX-4bit", maxTokens: 512)
        #expect(tight.forcedThinkingTokens == nil)
    }

    @Test("with argv's budget in hand, only a template that pre-opens a thought reports it", arguments: [
        ("mlx-community/Qwen3.5-4B-MLX-4bit", 2048),
        ("mlx-community/gemma-4-12B-it-4bit", nil),
        ("mlx-community/Qwen3-4B-Instruct-2507-4bit-DWQ-2510", nil),
    ] as [(String, Int?)])
    func forcedThinkingFollowsTheTemplate(modelID: String, expected: Int?) throws {
        let suite = "PerTurnThinkingTests-\(UUID().uuidString)"
        let argv = try #require(UserDefaults(suiteName: suite))
        defer { argv.removePersistentDomain(forName: suite) }
        argv.set("2048", forKey: ThinkBudget.tokensKey)
        #expect(MLXBrainProvider(modelID: modelID, defaults: argv).forcedThinkingTokens == expected)
    }
}
