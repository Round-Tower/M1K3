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
//  Review: Kev + claude-opus-5-5, 2026-09-27 — `servedMini` unwraps through `BackendRouting`.
//  It cast to SwappableInferenceProvider only, and the Mac responder holds the app's
//  RuntimeInferenceProvider, so the route never ran in the shipped Mac app (build 373: a news
//  ask took the native session, overflowed at 5,509 tokens, and answered from local notes).
//  iOS holds the swappable directly and was unaffected. Confidence 0.9.
//  Review: same day, #423 review nit — the unwrap bound is named (`maxFacadeDepth`).
//  Review: Kev + claude-opus-5-5, 2026-10-07 — every brain can take the route (`toolRouterAllTiers`,
//  absent = OFF): a tool turn on Lil or Big is picked by Apple's model and run by the app (ADR 0009),
//  so the brain answers with the result in hand and never writes a tool call (Qwen3.5 needs thinking
//  for a well-formed one). Unmeasured on Lil/Big, whose prompt cache was keyed on the palette: the
//  eval's `_ROUTER=dispatch` arm runs this exact route first. Where Apple's model isn't ready the pick
//  throws → nil → the agent turn. The pick is a cascade: the trained group head (ToolGroupRouter, no
//  model in the loop, `toolGroupRouter`, absent = OFF: ADR 0009's spike rejected a per-group router),
//  then Apple's pick, then the agent. Confidence 0.7.
//

import Foundation
import M1K3Inference
import M1K3LogCore
import os

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

    /// The group head in front of the picker: absent = OFF. ADR 0009's spike found a
    /// per-group router too loose to pick alone; this one also needs the family's words
    /// and falls back to Apple's pick, but it is an experiment until an arm measures it.
    public static let groupRouterKey = "toolGroupRouter"

    public static func groupRouterEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: groupRouterKey)
    }

    /// The route for every brain, not only Mini: absent = OFF until the eval arm
    /// (`M1K3_SELFTEST_CHATEVAL_ROUTER=dispatch`) has measured Lil and Big on it.
    public static let allTiersKey = "toolRouterAllTiers"

    public static func allTiersEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: allTiersKey)
    }

    /// Loaded once: the embedding asset is read-only and shared across turns.
    private static let embedder = NLSentenceEmbedder()

    private static let log = M1K3Log.logger(.route)

    /// Apple's model as a picker for a brain that isn't Mini (all tiers). A fresh
    /// session per pick: it never touches a chat prewarm. Not ready → the pick throws → nil.
    private static let fallbackPicker = AppleFoundationModelsProvider()

    /// This turn's plain-chat route, or nil for today's agent turn.
    /// The route keeps the provider's own persona (nil). On Mini that is its trimmed,
    /// prewarmed one: first chosen the other way (the agent turns' standard persona, for
    /// its voice and chips); reversed the same day on evidence: with a tool result in the
    /// prompt the standard persona narrated 12 of 39 answers in the third person, Mini's
    /// own 0 of 100, and it's faster. Mini's synthesised tool answers always used this one.
    /// `allTiers` gives a brain that isn't Mini the route too (unmeasured; flagged off).
    public static func route(
        provider: any InferenceProvider, enabled: Bool, dispatch: Bool = false,
        groupRouter: Bool = false, allTiers: Bool = false
    ) -> PlainTurnRoute? {
        guard enabled else { return nil }
        let mini = servedMini(provider)
        guard mini != nil || allTiers else { return nil }
        var picker: (@Sendable (String, String) async -> ToolPick?)?
        if dispatch {
            let fallback: (any ToolPicking)? = mini ?? fallbackPicker
            let classify: (@Sendable (String) -> ToolPick?)? = groupRouter
                ? { ToolGroupRouter.pick(for: $0, embed: embedder.vector) }
                : nil
            picker = { question, menu in await cascade(question: question, menu: menu, classify: classify, fallback: fallback) }
        }
        return PlainTurnRoute(
            decide: { ToolNeedRouter.decide(for: $0, embed: embedder.vector) },
            instructions: nil,
            pick: picker
        )
    }

    /// The pick for a tools-verdict turn: the group head if it speaks, else the
    /// fallback picker, else nil (the agent turn). Each stage fails open to the next.
    static func cascade(
        question: String, menu: String,
        classify: (@Sendable (String) -> ToolPick?)?, fallback: (any ToolPicking)?
    ) async -> ToolPick? {
        if let picked = classify?(question) {
            log.notice("tool pick: group head → \(picked.tool, privacy: .public)")
            return picked
        }
        guard let fallback else { return nil }
        return await pick(with: fallback, question: question, menu: menu)
    }

    /// Mini names one tool from the menu; any failure (a guardrail, the daemon) is
    /// nil, which keeps the agent turn.
    static func pick(with picker: some ToolPicking, question: String, menu: String) async -> ToolPick? {
        guard let choice = try? await picker.pickTool(
            message: question, instructions: ToolDispatch.pickerInstructions + "\n\n" + menu
        ) else { return nil }
        return ToolPick(tool: choice.tool, query: choice.query)
    }

    /// Headroom over today's two façade levels, not a measured depth: it only guards a
    /// façade that routes to itself, which then fails to the agent turn.
    static let maxFacadeDepth = 4

    /// The brain serving this turn, through every façade (the app's RuntimeInferenceProvider
    /// over a SwappableInferenceProvider, today). A cast to one façade type alone left the
    /// route dead in the shipped Mac app (build 373) while every eval, holding the bare
    /// provider, passed.
    static func servedMini(_ provider: any InferenceProvider) -> AppleFoundationModelsProvider? {
        var serving = provider
        for _ in 0 ..< maxFacadeDepth {
            guard let facade = serving as? BackendRouting else { break }
            serving = facade.routedBackend
        }
        return serving as? AppleFoundationModelsProvider
    }
}
