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
//  then Apple's pick, then the agent. `toolChain` (absent = OFF) lets a pick carry a second read-only
//  tool (Apple's pick gets an `also` slot; the head chains two named device tools). All tiers also
//  routes a chat verdict to the plain turn on Lil/Big (ADR 0008 measured no gain on Lil there), so the
//  arm measures the two together.
//  Confidence 0.7.
//  Review: Kev + claude-fable-5.1, 2026-10-09 — the gate and the head share one sentence vector per
//  turn (`OneTurnEmbedder`, #512).
//  Review: Kev + claude-opus-5-5, 2026-10-10 — the cascade reports its stage (head / picker / agent) to a
//  @TaskLocal `PickStageRecorder` the eval sets; nil on every shipping turn. The 10-09 arm couldn't see
//  that the head never fired. Confidence 0.85 (the cascade side is pinned; the eval wiring is by launch).
//  Review: Kev + claude-opus-5-5, 2026-10-10 — each flag reader takes `whenUnset:` (an explicit setting still
//  wins), so a shell picks the default: the Mac turns them on after the 10-10 arm, iOS keeps them off.
//

import Foundation
import M1K3Inference
import M1K3LogCore
import os
import Synchronization

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

    public static func groupRouterEnabled(_ defaults: UserDefaults = .standard, whenUnset: Bool = false) -> Bool {
        flag(groupRouterKey, defaults, whenUnset: whenUnset)
    }

    /// The route for every brain, not only Mini: absent = OFF until the eval arm
    /// (`M1K3_SELFTEST_CHATEVAL_ROUTER=dispatch`) has measured Lil and Big on it.
    public static let allTiersKey = "toolRouterAllTiers"

    public static func allTiersEnabled(_ defaults: UserDefaults = .standard, whenUnset: Bool = false) -> Bool {
        flag(allTiersKey, defaults, whenUnset: whenUnset)
    }

    /// Chains: a tool turn may run two read-only tools ("the weather and my calendar").
    /// Absent = OFF: Apple's pick gets a second slot, which the eval arm measures first.
    public static let chainKey = "toolChain"

    public static func chainEnabled(_ defaults: UserDefaults = .standard, whenUnset: Bool = false) -> Bool {
        flag(chainKey, defaults, whenUnset: whenUnset)
    }

    /// An explicit setting wins; absent, the shell's default (`whenUnset`). The shells choose:
    /// the Mac turns the router flags on (the 2026-10-10 arm), iOS keeps them off until a phone
    /// smoke (Lil + Apple's picker on an 8 GB iPhone is unmeasured).
    private static func flag(_ key: String, _ defaults: UserDefaults, whenUnset: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? whenUnset : defaults.bool(forKey: key)
    }

    /// Loaded once: the embedding asset is read-only and shared across turns.
    private static let embedder = NLSentenceEmbedder()

    /// The gate (ToolNeedRouter) and the group head embed the same turn text: one vector for both.
    private static let turnEmbedder = OneTurnEmbedder(embedder.vector)

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
        groupRouter: Bool = false, allTiers: Bool = false, chain: Bool = false
    ) -> PlainTurnRoute? {
        guard enabled else { return nil }
        let mini = servedMini(provider)
        guard mini != nil || allTiers else { return nil }
        var picker: (@Sendable (String, String) async -> ToolPick?)?
        if dispatch {
            let fallback: (any ToolPicking)? = mini ?? fallbackPicker
            // Typed if/else, not a ternary closure: that shape crashed the app build's
            // type checker once (ChatEvalStage's header).
            var classify: (@Sendable (String) -> ToolPick?)?
            if groupRouter {
                classify = { ToolGroupRouter.pick(for: $0, embed: turnEmbedder.vector, chain: chain) }
            }
            // `[classify]`: a captured var can't be read from a @Sendable closure (Swift 6).
            picker = { [classify] question, menu in
                await cascade(question: question, menu: menu, classify: classify, fallback: fallback, chain: chain)
            }
        }
        return PlainTurnRoute(
            decide: { ToolNeedRouter.decide(for: $0, embed: turnEmbedder.vector) },
            instructions: nil,
            pick: picker
        )
    }

    /// Set by the eval around one fixture's turn (ChatEvalStage); nil on every shipping turn.
    @TaskLocal public static var pickRecorder: PickStageRecorder?

    /// The pick for a tools-verdict turn: the group head if it speaks, else the
    /// fallback picker, else nil (the agent turn). Each stage fails open to the next.
    static func cascade(
        question: String, menu: String,
        classify: (@Sendable (String) -> ToolPick?)?, fallback: (any ToolPicking)?, chain: Bool = false
    ) async -> ToolPick? {
        if let picked = classify?(question) {
            log.notice("tool pick: group head → \(picked.tool, privacy: .public)")
            pickRecorder?.record(.head)
            return picked
        }
        guard let fallback else {
            pickRecorder?.record(.agent)
            return nil
        }
        let picked = await pick(with: fallback, question: question, menu: menu, chain: chain)
        pickRecorder?.record(picked == nil ? .agent : .picker)
        return picked
    }

    /// Apple's model names one tool from the menu (two with `chain`: the second rides
    /// as `then`); any failure (a guardrail, the daemon) is nil, which keeps the agent turn.
    static func pick(with picker: some ToolPicking, question: String, menu: String, chain: Bool = false) async -> ToolPick? {
        let rules = chain
            ? ToolDispatch.pickerInstructions + "\n" + ToolDispatch.chainInstructions
            : ToolDispatch.pickerInstructions
        let instructions = rules + "\n\n" + menu
        if chain {
            guard let picks = try? await picker.pickTools(message: question, instructions: instructions),
                  let first = picks.first
            else { return nil }
            return ToolPick(
                tool: first.tool, query: first.query,
                then: picks.dropFirst().map { ToolPick(tool: $0.tool, query: $0.query) }
            )
        }
        guard let choice = try? await picker.pickTool(message: question, instructions: instructions) else { return nil }
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

/// Remembers the last text's vector, so the gate and the group head, which ask for the same
/// turn one after the other, embed it once. One entry: a new turn replaces it.
final class OneTurnEmbedder: Sendable {
    private let embed: @Sendable (String) -> [Double]?
    private let last = Mutex<(text: String, vector: [Double]?)?>(nil)

    init(_ embed: @escaping @Sendable (String) -> [Double]?) {
        self.embed = embed
    }

    func vector(_ text: String) -> [Double]? {
        if let hit = last.withLock({ $0 }), hit.text == text { return hit.vector }
        let vector = embed(text)
        last.withLock { $0 = (text, vector) }
        return vector
    }
}

/// Which stage named a tool turn's pick: the group head, Apple's picker, or neither (the
/// agent turn). The router arm of 2026-10-09 couldn't tell: the head's notice went to os_log,
/// so a head that never fired read as a head that won.
public enum PickStage: String, Sendable, Codable {
    case head
    case picker
    case agent
}

/// An eval's ear on the cascade: the stages this task's tool turns took, in order.
public final class PickStageRecorder: Sendable {
    private let recorded = Mutex<[PickStage]>([])

    public init() {}

    public var stages: [PickStage] {
        recorded.withLock { $0 }
    }

    func record(_ stage: PickStage) {
        recorded.withLock { $0.append(stage) }
    }
}
