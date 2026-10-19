//
//  SamplingProfile.swift
//  M1K3Inference
//
//  How an MLX brain samples each token. Until 2026-09-23 every MLX brain ran
//  mlx-swift-lm's generic defaults (temperature 0.6, top-p 1.0, top-k off)
//  plus our 1.1 repetition penalty over 64 tokens — including Lil, whose own
//  model card recommends temperature 0.7, top-p 0.8, top-k 20. Kev found Lil
//  "a little too terse, a little boring"; sampling is one suspect, the persona
//  the other.
//
//  `house` is today's behaviour exactly, and stays the default for every model
//  until an eval earns a card profile its place. The arms are chosen by
//  `M1K3_SAMPLING` (SelfTest / run_chateval pass the environment through):
//    card           the model card's sampling, our loop guard kept (the retired
//                   Qwen3-2507 only)
//    card-presence  the same with Qwen's presence penalty (0.5) instead of the
//                   repetition penalty — which the loop-guard note warns can
//                   distort tool-call JSON at ≥1.2, so gated (2507 only)
//    card-mode      each current family's card, thinking vs straight per
//                   generation (Qwen3.5, Gemma 4, LFM2.5; `modeCard`)
//
//  Pure (no MLX): the provider maps a profile onto GenerateParameters.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-23, Confidence 0.85 (the house
//  profile is pinned to today's values; which arm wins is the eval's call).
//  Prior: Unknown
//  Review: Kev + claude-opus-5-5, 2026-10-09 — comment only: Qwen3.5 Lil has no card arm on purpose.
//  Review: Kev + claude-opus-5-5, 2026-10-18 — `card-mode`: each family's card, per turn mode. The cards
//  were read 2026-10-18 (Qwen/Qwen3.5-4B, google/gemma-4-12b-it, LiquidAI/LFM2.5-1.2B-Instruct on HF).
//  The provider picks thinking vs instruct per generation from the turn's decision. `house` stays the
//  default until the eval earns the flip. Confidence 0.7: the card values are copied; whether they beat
//  house on a 4-bit 4B is the eval's question.
//  Review: Kev + claude-opus-5-5, 2026-10-19 — comments only: the header names card-mode and scopes card /
//  card-presence to the retired 2507, and the presence window is dated (64 since df548535, mlx's 20 before, so the
//  09-23 card-presence cells sampled 20). #643's review.
//

public struct SamplingProfile: Sendable, Equatable {
    public var temperature: Float
    public var topP: Float
    public var topK: Int
    public var minP: Float
    public var repetitionPenalty: Float?
    public var repetitionContextSize: Int
    public var presencePenalty: Float?

    public init(
        temperature: Float,
        topP: Float,
        topK: Int,
        minP: Float = 0,
        repetitionPenalty: Float? = 1.1,
        repetitionContextSize: Int = 64,
        presencePenalty: Float? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.repetitionPenalty = repetitionPenalty
        self.repetitionContextSize = repetitionContextSize
        self.presencePenalty = presencePenalty
    }

    /// The environment key that picks an experiment arm.
    public static let overrideKey = "M1K3_SAMPLING"

    /// What every MLX brain sampled before profiles existed.
    public static let house = SamplingProfile(temperature: 0.6, topP: 1.0, topK: 0)

    /// The `card` / `card-presence` arms' sampling, by model family: only the retired Qwen3-2507 has an entry.
    /// The current families' cards (read 2026-10-18) live in `modeCard`, the card-mode arm.
    private static func card(for modelID: String) -> SamplingProfile? {
        let id = modelID.lowercased()
        // Qwen3-*-Instruct-2507 (Lil until 2026-10-08): temperature 0.7, top-p 0.8, top-k 20, min-p 0.
        // Qwen3.5 (Lil since) has no entry here on purpose: its card's per-mode values are card-mode's
        // (`modeCard`), so under `card` / `card-presence` it samples `house`.
        if id.contains("qwen3"), id.contains("instruct-2507") {
            return SamplingProfile(temperature: 0.7, topP: 0.8, topK: 20)
        }
        return nil
    }

    /// The card's sampling per turn mode (`card-mode`), by family. Cards read on 2026-10-18:
    /// - Qwen3.5 (Lil): thinking 1.0 / 0.95 / 20 with presence 1.5; instruct 0.7 / 0.8 / 20 with
    ///   presence 1.5; repetition penalty off (1.0) in both. The card's "precise coding" (0.6) and its
    ///   two disagreeing "non-thinking reasoning" rows are left out.
    /// - Gemma 4 (Big): one recipe for every use, 1.0 / 0.95 / 64, no penalties named.
    /// - LFM2.5 (pocket): 0.1, top-k 50, repetition penalty 1.05; no top-p named.
    /// Presence penalty spans `repetitionContextSize` tokens (64, since df548535 on 2026-10-18; mlx's default
    /// window of 20 before, so the 09-23 card-presence cells sampled 20). The card's servers apply it to the
    /// whole output, so this is the milder reading.
    private static func modeCard(for modelID: String, thinking: Bool) -> SamplingProfile? {
        let id = modelID.lowercased()
        if id.contains("qwen3.5") {
            return thinking
                ? SamplingProfile(temperature: 1.0, topP: 0.95, topK: 20, repetitionPenalty: nil, presencePenalty: 1.5)
                : SamplingProfile(temperature: 0.7, topP: 0.8, topK: 20, repetitionPenalty: nil, presencePenalty: 1.5)
        }
        if id.contains("gemma-4") {
            return SamplingProfile(temperature: 1.0, topP: 0.95, topK: 64, repetitionPenalty: nil)
        }
        if id.contains("lfm2.5") {
            return SamplingProfile(temperature: 0.1, topP: 1.0, topK: 50, repetitionPenalty: 1.05)
        }
        return nil
    }

    /// The `card-mode` arm's name.
    public static let cardModeArm = "card-mode"

    /// The profile for one generation, given the turn's thinking decision. Only
    /// `card-mode` reads the mode; every other arm (and no arm) is `resolve(modelID:environment:)`.
    public static func resolve(modelID: String, environment: [String: String], thinking: Bool) -> SamplingProfile {
        guard environment[overrideKey] == cardModeArm else {
            return resolve(modelID: modelID, environment: environment)
        }
        return modeCard(for: modelID, thinking: thinking) ?? house
    }

    /// The profile a model runs with: `house` unless an arm is requested AND the
    /// model has a card entry.
    public static func resolve(modelID: String, environment: [String: String]) -> SamplingProfile {
        guard let arm = environment[overrideKey], var card = card(for: modelID) else { return house }
        switch arm {
        case "card":
            return card
        case "card-presence":
            card.repetitionPenalty = nil
            card.presencePenalty = 0.5
            return card
        default:
            return house
        }
    }
}
