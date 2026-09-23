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
//    card           the model card's sampling, our loop guard kept
//    card-presence  the card's sampling with Qwen's presence penalty (0.5)
//                   instead of the repetition penalty — which the loop-guard
//                   note warns can distort tool-call JSON at ≥1.2, so gated.
//
//  Pure (no MLX): the provider maps a profile onto GenerateParameters.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-23, Confidence 0.85 (the house
//  profile is pinned to today's values; which arm wins is the eval's call).
//  Prior: Unknown
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

    /// Model-card sampling, by model family. Only families whose card we've read.
    private static func card(for modelID: String) -> SamplingProfile? {
        let id = modelID.lowercased()
        // Qwen3-*-Instruct-2507 (Lil): temperature 0.7, top-p 0.8, top-k 20, min-p 0.
        if id.contains("qwen3"), id.contains("instruct-2507") {
            return SamplingProfile(temperature: 0.7, topP: 0.8, topK: 20)
        }
        return nil
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
