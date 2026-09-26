//
//  ToolRouterWiring.swift
//  M1K3Chat
//
//  The one place both shells ask whether a turn gets the tool router
//  (ToolNeedRouter): the flag is on AND the brain answering is Apple's
//  on-device model. The live A/B that justified the plain-chat route was
//  measured on AFM; the MLX tiers (and the pocket Mini, LFM2 on MLX) key their
//  prompt cache on the palette, so a per-turn palette would thrash it.
//
//  Default OFF until the route's own eval arm has run (chat, tool-use, security).
//
//  Signed: Kev + claude-opus-5-5, 2026-09-26, Confidence 0.85. Prior: Unknown.
//

import M1K3Inference

public enum ToolRouterWiring {
    /// UserDefaults Bool; absent = off.
    public static let enabledKey = "miniToolRouter"

    /// Loaded once: the embedding asset is read-only and shared across turns.
    private static let embedder = NLSentenceEmbedder()

    /// This turn's plain-chat route, or nil for today's agent turn.
    public static func route(provider: any InferenceProvider, enabled: Bool) -> PlainTurnRoute? {
        guard enabled, servesMini(provider) else { return nil }
        return PlainTurnRoute(
            decide: { ToolNeedRouter.decide(for: $0, embed: embedder.vector) },
            instructions: nil
        )
    }

    static func servesMini(_ provider: any InferenceProvider) -> Bool {
        let active = (provider as? SwappableInferenceProvider)?.active ?? provider
        return active is AppleFoundationModelsProvider
    }
}
