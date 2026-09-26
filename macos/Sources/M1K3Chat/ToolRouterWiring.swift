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
//  Review: same day, reversed on evidence (dispatch arm): the standard persona narrated
//  12/39 answers in the third person once tool results sat in the prompt; Mini's own 0/100.
//  The route keeps Mini's persona; routed turns lose follow-up chips. Confidence 0.85.
//

import Foundation
import M1K3Inference

public enum ToolRouterWiring {
    /// UserDefaults Bool; absent = ON (Kev, 2026-09-26). Only an explicit false turns it off.
    public static let enabledKey = "miniToolRouter"

    public static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) == nil || defaults.bool(forKey: enabledKey)
    }

    /// Router-invoked tools: its own kill switch, absent = ON. Off, a tools verdict
    /// takes the agent turn as before.
    public static let dispatchKey = "miniToolDispatch"

    public static func dispatchEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: dispatchKey) == nil || defaults.bool(forKey: dispatchKey)
    }

    /// Loaded once: the embedding asset is read-only and shared across turns.
    private static let embedder = NLSentenceEmbedder()

    /// This turn's plain-chat route, or nil for today's agent turn.
    /// The route keeps Mini's own trimmed, prewarmed persona (nil = the provider's).
    /// First chosen the other way (the agent turns' standard persona, for its voice and
    /// chips); reversed the same day on evidence: with a tool result in the prompt the
    /// standard persona narrated 12 of 39 answers in the third person, Mini's own 0 of
    /// 100, and it's faster. Mini's synthesised tool answers always used this one.
    public static func route(provider: any InferenceProvider, enabled: Bool, dispatch: Bool = false) -> PlainTurnRoute? {
        guard enabled, let mini = servedMini(provider) else { return nil }
        var picker: (@Sendable (String, String) async -> ToolPick?)?
        if dispatch {
            picker = { question, menu in await pick(with: mini, question: question, menu: menu) }
        }
        return PlainTurnRoute(
            decide: { ToolNeedRouter.decide(for: $0, embed: embedder.vector) },
            instructions: nil,
            pick: picker
        )
    }

    /// Mini names one tool from the menu; any failure (a guardrail, the daemon) is
    /// nil, which keeps the agent turn.
    static func pick(with picker: some ToolPicking, question: String, menu: String) async -> ToolPick? {
        guard let choice = try? await picker.pickTool(
            message: question, instructions: ToolDispatch.pickerInstructions + "\n\n" + menu
        ) else { return nil }
        return ToolPick(tool: choice.tool, query: choice.query)
    }

    static func servedMini(_ provider: any InferenceProvider) -> AppleFoundationModelsProvider? {
        ((provider as? SwappableInferenceProvider)?.active ?? provider) as? AppleFoundationModelsProvider
    }
}
