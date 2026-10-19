//
//  SamplingProfileTests.swift
//  M1K3InferenceTests
//
//  How an MLX brain samples. Lil ran mlx-swift-lm's generic defaults
//  (temperature 0.6, top-p 1.0, top-k off) though its own card recommends
//  0.7 / 0.8 / 20 — one suspect for "a little too terse, a little boring"
//  (Kev, 2026-09-23). The house profile is today's behaviour, byte for byte;
//  the card profile is the experiment arm, chosen by M1K3_SAMPLING until an
//  eval earns it the default.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-23, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-10-09 — the card arm belongs to the Qwen3 2507 (Lil until
//  2026-10-08), named as such; the shipped Lil (Qwen3.5-4B, #517) has no card entry and stays `house`
//  under every arm until an eval reads its card — pinned, green from the start.
//  Review: Kev + claude-opus-5-5, 2026-10-18 — `card-mode`: each family's card per turn mode (Qwen3.5
//  thinking vs instruct, Gemma 4, LFM2.5; cards read 2026-10-18); every other arm and no arm unchanged.
//  Review: Kev + claude-opus-5-5, 2026-10-19 — comments and one test name only: Lil's card was read (card-mode),
//  so "no card arm until an eval reads its card" was stale.
//

@testable import M1K3Inference
import Testing

struct SamplingProfileTests {
    /// The one family with a `card` / `card-presence` entry — Lil from 2026-07-16 to 2026-10-08, now retired.
    private let qwen2507 = "mlx-community/Qwen3-4B-Instruct-2507-4bit-DWQ-2510"
    /// The shipped Lil (#517): no `card` entry on purpose; its card's values are card-mode's.
    private let lil = "mlx-community/Qwen3.5-4B-MLX-4bit"
    private let big = "mlx-community/gemma-4-12B-it-4bit"

    @Test("the house profile is exactly what every brain sampled before")
    func houseIsToday() {
        let house = SamplingProfile.house
        #expect(house.temperature == 0.6)
        #expect(house.topP == 1.0)
        #expect(house.topK == 0)
        #expect(house.minP == 0)
        #expect(house.repetitionPenalty == 1.1)
        #expect(house.repetitionContextSize == 64)
        #expect(house.presencePenalty == nil)
    }

    @Test("with no override every model keeps the house profile (no behaviour change yet)")
    func defaultIsHouse() {
        #expect(SamplingProfile.resolve(modelID: lil, environment: [:]) == .house)
        #expect(SamplingProfile.resolve(modelID: qwen2507, environment: [:]) == .house)
        #expect(SamplingProfile.resolve(modelID: big, environment: [:]) == .house)
    }

    @Test("the shipped Lil (Qwen3.5-4B) has no card / card-presence entry: house under both (its card is card-mode's)")
    func shippedLilStaysHouse() {
        for arm in ["card", "card-presence"] {
            #expect(SamplingProfile.resolve(modelID: lil, environment: [SamplingProfile.overrideKey: arm]) == .house)
        }
    }

    @Test("the card arm gives Qwen3 2507 its model card's sampling, loop guard kept")
    func cardForQwen2507() {
        let card = SamplingProfile.resolve(modelID: qwen2507, environment: [SamplingProfile.overrideKey: "card"])
        #expect(card.temperature == 0.7)
        #expect(card.topP == 0.8)
        #expect(card.topK == 20)
        #expect(card.minP == 0)
        #expect(card.repetitionPenalty == 1.1)
        #expect(card.presencePenalty == nil)
    }

    @Test("the presence arm swaps the repetition penalty for Qwen's recommended presence penalty")
    func presenceArm() {
        let arm = SamplingProfile.resolve(modelID: qwen2507, environment: [SamplingProfile.overrideKey: "card-presence"])
        #expect(arm.topK == 20)
        #expect(arm.repetitionPenalty == nil)
        #expect(arm.presencePenalty == 0.5)
    }

    @Test("a model with no card entry keeps the house profile even under an override")
    func unknownModelStaysHouse() {
        #expect(SamplingProfile.resolve(modelID: big, environment: [SamplingProfile.overrideKey: "card"]) == .house)
        #expect(SamplingProfile.resolve(modelID: qwen2507, environment: [SamplingProfile.overrideKey: "nonsense"]) == .house)
    }

    // MARK: - card-mode (2026-10-18): the card's sampling per turn mode

    private let pocket = "mlx-community/LFM2.5-1.2B-Instruct-4bit"
    private func cardMode(_ id: String, thinking: Bool) -> SamplingProfile {
        SamplingProfile.resolve(modelID: id, environment: [SamplingProfile.overrideKey: "card-mode"], thinking: thinking)
    }

    @Test("card-mode gives Lil Qwen3.5's thinking-mode card on a thinking turn, no repetition penalty")
    func lilThinkingCard() {
        let p = cardMode(lil, thinking: true)
        #expect(p.temperature == 1.0)
        #expect(p.topP == 0.95)
        #expect(p.topK == 20)
        #expect(p.minP == 0)
        #expect(p.presencePenalty == 1.5)
        #expect(p.repetitionPenalty == nil)
    }

    @Test("card-mode gives Lil Qwen3.5's instruct card on a straight turn")
    func lilInstructCard() {
        let p = cardMode(lil, thinking: false)
        #expect(p.temperature == 0.7)
        #expect(p.topP == 0.8)
        #expect(p.topK == 20)
        #expect(p.presencePenalty == 1.5)
        #expect(p.repetitionPenalty == nil)
    }

    @Test("card-mode gives Big Gemma 4's one card in both modes")
    func bigCard() {
        for thinking in [true, false] {
            let p = cardMode(big, thinking: thinking)
            #expect(p.temperature == 1.0)
            #expect(p.topP == 0.95)
            #expect(p.topK == 64)
            #expect(p.repetitionPenalty == nil)
            #expect(p.presencePenalty == nil)
        }
    }

    @Test("card-mode gives pocket LFM2.5's card: near-greedy with its own light repetition penalty")
    func pocketCard() {
        let p = cardMode(pocket, thinking: false)
        #expect(p.temperature == 0.1)
        #expect(p.topK == 50)
        #expect(p.topP == 1.0)
        #expect(p.repetitionPenalty == 1.05)
        #expect(p.presencePenalty == nil)
    }

    @Test("without card-mode the mode-aware resolve is exactly today's resolve")
    func modeAwareResolveKeepsOtherArms() {
        for env in [[:], [SamplingProfile.overrideKey: "card"], [SamplingProfile.overrideKey: "nonsense"]] {
            for id in [lil, big, pocket, qwen2507] {
                for thinking in [true, false] {
                    #expect(SamplingProfile.resolve(modelID: id, environment: env, thinking: thinking)
                        == SamplingProfile.resolve(modelID: id, environment: env))
                }
            }
        }
    }

    @Test("card-mode on a family with no mode card keeps the house profile")
    func cardModeUnknownStaysHouse() {
        #expect(cardMode("mlx-community/Llama-3.2-1B-Instruct-4bit", thinking: true) == .house)
        #expect(cardMode(qwen2507, thinking: false) == .house)
    }
}
