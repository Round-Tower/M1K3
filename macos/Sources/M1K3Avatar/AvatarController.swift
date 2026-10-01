//
//  AvatarController.swift
//  M1K3Avatar
//
//  Observable state owner for the avatar companion panel. Driven by AppEnvironment
//  at every meaningful transition (dictation → thinking → generating → speaking).
//  Pure: no RealityKit, no UI dep — safe to `swift test`.
//
//  Signed: Kev + claude-sonnet-4-6, 2026-06-08, Confidence 0.9, Prior: Unknown
//  Review: Kev + claude-opus-5-5, 2026-10-01 — `setEmotion` is remembered and survives `setActivity` until
//  `resetToIdle` (an MCP `speak` emotion was wiped by `setActivity(.speaking)`; companions played 2/3 of
//  their clips). `.error` drops it. Confidence now 0.85.

import Observation

@MainActor
@Observable
public final class AvatarController {
    public private(set) var state: AvatarState = .idle

    /// An emotion somebody SET on purpose (an MCP `speak` emotion, a sparkle) as
    /// opposed to one `fromActivity` derived. It outlives `setActivity` calls
    /// within the turn — before this, `setActivity(.speaking)` wiped the emotion
    /// the model had just chosen — and is cleared by `resetToIdle`.
    private var explicitEmotion: AvatarEmotion?

    public init() {}

    public func setActivity(_ activity: AvatarActivity) {
        let derived = AvatarState.fromActivity(activity)
        // Error is the app's own verdict on the turn; it neither borrows nor
        // keeps a stale explicit emotion.
        if activity == .error { explicitEmotion = nil }
        state = AvatarState(emotion: explicitEmotion ?? derived.emotion, activity: activity)
    }

    public func setEmotion(_ emotion: AvatarEmotion) {
        explicitEmotion = emotion
        state = AvatarState(emotion: emotion, activity: state.activity)
    }

    public func resetToIdle() {
        explicitEmotion = nil
        state = .idle
    }
}
