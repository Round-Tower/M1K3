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
//

@testable import M1K3Inference
import Testing

struct SamplingProfileTests {
    private let lil = "mlx-community/Qwen3-4B-Instruct-2507-4bit-DWQ-2510"
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
        #expect(SamplingProfile.resolve(modelID: big, environment: [:]) == .house)
    }

    @Test("the card arm gives Qwen3 2507 its model card's sampling, loop guard kept")
    func cardForQwen2507() {
        let card = SamplingProfile.resolve(modelID: lil, environment: [SamplingProfile.overrideKey: "card"])
        #expect(card.temperature == 0.7)
        #expect(card.topP == 0.8)
        #expect(card.topK == 20)
        #expect(card.minP == 0)
        #expect(card.repetitionPenalty == 1.1)
        #expect(card.presencePenalty == nil)
    }

    @Test("the presence arm swaps the repetition penalty for Qwen's recommended presence penalty")
    func presenceArm() {
        let arm = SamplingProfile.resolve(modelID: lil, environment: [SamplingProfile.overrideKey: "card-presence"])
        #expect(arm.topK == 20)
        #expect(arm.repetitionPenalty == nil)
        #expect(arm.presencePenalty == 0.5)
    }

    @Test("a model with no card entry keeps the house profile even under an override")
    func unknownModelStaysHouse() {
        #expect(SamplingProfile.resolve(modelID: big, environment: [SamplingProfile.overrideKey: "card"]) == .house)
        #expect(SamplingProfile.resolve(modelID: lil, environment: [SamplingProfile.overrideKey: "nonsense"]) == .house)
    }
}
