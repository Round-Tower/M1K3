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
//  Default ON (Kev, 2026-09-26) after the route's own eval arm: Mini open chat 51.1 s →
//  10.1 s, tool use 10/10, security unchanged. `miniToolRouter = false` turns it off.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-26, Confidence 0.85. Prior: Unknown.
//  Review: Kev + claude-opus-5-5, 2026-09-26 — the route's persona is the agent turns'
//  (Kev's call on the voice-vs-speed trade-off), not Mini's trimmed prewarmed one.
//

import Foundation
import M1K3Inference

public enum ToolRouterWiring {
    /// UserDefaults Bool; absent = ON (Kev, 2026-09-26). Only an explicit false turns it off.
    public static let enabledKey = "miniToolRouter"

    public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) == nil || defaults.bool(forKey: enabledKey)
    }

    /// Loaded once: the embedding asset is read-only and shared across turns.
    private static let embedder = NLSentenceEmbedder()

    /// This turn's plain-chat route, or nil for today's agent turn.
    /// The route speaks in the persona Mini's agent turns use (Kev, 2026-09-26): the
    /// same voice and follow-up chips on either route, for ~0.7 s of first-word time
    /// over Mini's trimmed prewarmed persona (live A/B, 5.1 s against 4.4 s).
    public static func route(provider: any InferenceProvider, enabled: Bool) -> PlainTurnRoute? {
        guard enabled, let mini = servedMini(provider) else { return nil }
        return PlainTurnRoute(
            decide: { ToolNeedRouter.decide(for: $0, embed: embedder.vector) },
            instructions: M1K3Persona.systemPrompt(variant: mini.personaVariant)
        )
    }

    static func servedMini(_ provider: any InferenceProvider) -> AppleFoundationModelsProvider? {
        ((provider as? SwappableInferenceProvider)?.active ?? provider) as? AppleFoundationModelsProvider
    }
}
