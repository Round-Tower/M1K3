//
//  EvalThinkingPlan.swift
//  M1K3Eval
//
//  How a ChatEval brain thinks, per arm. The default (`tier`) is production's
//  shape: the app's Lil runs Auto with the speed-tier bias (it thinks only on an
//  explicit deep ask — ~3 of ~90 fixtures), Big thinks on grounded/analytic/long
//  asks. Before this the eval let a thinking brain think on EVERY bare turn and
//  gave the live arm Big's policy whatever the tier, so the 2026-10-06 shootout
//  scored Qwen3.5 on a think budget the app would almost never spend.
//
//  `always` / `fast` are the A/B arms (`M1K3_SELFTEST_CHATEVAL_THINKING`).
//  A brain whose template has no thinking toggle (dense Qwen3, gemma-4) is
//  unaffected either way.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-06, Confidence 0.85, Prior: none (new
//  file; GEMMA_1_1_PLAN critical pass, item 3).
//  Review: Kev + claude-opus-5.5, 2026-10-11 — the construction-flag gap is closed (#555); `bareThinks` scopes
//  the bare arms only.

import M1K3Inference

public enum EvalThinkingMode: String, Sendable, Equatable, CaseIterable {
    /// Production's shape for the tier (the default).
    case tier
    /// Every arm thinks.
    case always
    /// No arm thinks.
    case fast

    /// The env value, trimmed and case-folded; unset or unknown is `tier` —
    /// a typo must never quietly turn thinking on everywhere.
    public init(envValue: String?) {
        let raw = envValue?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        self = Self(rawValue: raw) ?? .tier
    }
}

public struct EvalThinkingPlan: Sendable, Equatable {
    /// Construction-time thinking for the arms with no per-question policy:
    /// bare `generate` and the tool-use agent loop, scoped per call through
    /// `InferenceIntent.withThinking`. The live arm ignores it: the responder sets
    /// the turn's decision itself, exactly as the app does. (#555 closed the gap
    /// where the plain route and the synthesis read the construction flag, which
    /// the app builds thinking-ON — so on Auto they thought without limit.)
    public let bareThinks: Bool
    /// The live responder's speed-tier bias — the app's `fastThinkingProvider`.
    public let liveFastByDefault: Bool
    /// nil runs the live arm in production Auto; true/false forces always/fast.
    public let liveForced: Bool?

    public init(tier: BrainTier, mode: EvalThinkingMode) {
        switch mode {
        case .tier:
            bareThinks = !tier.prefersFastThinking
            liveFastByDefault = tier.prefersFastThinking
            liveForced = nil
        case .always:
            bareThinks = true
            liveFastByDefault = tier.prefersFastThinking
            liveForced = true
        case .fast:
            bareThinks = false
            liveFastByDefault = tier.prefersFastThinking
            liveForced = false
        }
    }
}
