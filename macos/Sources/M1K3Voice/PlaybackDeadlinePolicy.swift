//
//  PlaybackDeadlinePolicy.swift
//  M1K3Voice
//
//  How long a playback wait may last before it is declared stalled, and what a
//  stall means for the engine. Pure value types so `swift test` pins them; the
//  AVAudioEngine glue that applies them is verify-by-launch.
//
//  Why a deadline exists (live 2026-10-02): a BLE headset in HFP mode grew the
//  output IO buffer to 512 frames while the engine's max frames per slice stayed
//  320. The engine kept RUNNING but every render failed
//  (kAudioUnitErr_TooManyFramesToProcess), so `.dataPlayedBack` never fired and
//  the completion wait suspended forever — jamming the entry gate for every later
//  utterance.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-02, Confidence 0.8, Prior: Unknown
//  (grace is a judgement: see `defaultGrace`).

import Foundation

/// Deadline for the completion wait: the audio's own duration plus a grace.
///
/// The wait starts after the last chunk is scheduled, when at most the whole
/// utterance is still unplayed, so `duration + grace` is a strict upper bound on
/// a healthy engine — a healthy playback can never trip it, however slowly the
/// chunks arrived.
public struct PlaybackDeadlinePolicy: Sendable, Equatable {
    /// Three seconds: comfortably more than a route-settling hiccup or a late
    /// completion callback on a loaded machine, short enough that a wedged
    /// utterance frees the gate before the next MCP `speak(wait:)` call times out.
    public static let defaultGrace: Duration = .seconds(3)

    public let grace: Duration

    public init(grace: Duration = PlaybackDeadlinePolicy.defaultGrace) {
        self.grace = grace
    }

    public func deadline(scheduledSamples: Int, sampleRate: Double) -> Duration {
        guard sampleRate > 0, scheduledSamples > 0 else { return grace }
        return .seconds(Double(scheduledSamples) / sampleRate) + grace
    }
}

/// How a bounded playback wait ended.
enum PlaybackOutcome: Equatable {
    /// Every scheduled buffer played back.
    case completed
    /// stop(), a barge-in or a route change cancelled it.
    case cancelled
    /// The deadline passed with buffers still pending — the engine is broken.
    case timedOut
}

/// What `configureEngineIfNeeded` must do, decided from observable state alone.
///
/// - A rebuild request (set when a deadline trips) beats `engine.isRunning`:
///   a running engine can be failing every render.
/// - The player is attached only if it is not already attached. `engineConfigured`
///   is cleared by a configuration change, but the node stays attached, so keying
///   `attach` on that flag attached it a second time.
struct EngineSetupPlan: Equatable {
    var teardown = false
    var attachPlayer = false
    var disconnectPlayer = false
    var startEngine = false

    var isNoOp: Bool {
        !teardown && !attachPlayer && !disconnectPlayer && !startEngine
    }

    static func make(
        configured: Bool,
        sampleRateMatches: Bool,
        engineRunning: Bool,
        playerAttached: Bool,
        needsRebuild: Bool
    ) -> EngineSetupPlan {
        if configured, sampleRateMatches, engineRunning, !needsRebuild { return EngineSetupPlan() }
        var plan = EngineSetupPlan()
        plan.teardown = needsRebuild
        plan.attachPlayer = !playerAttached
        plan.disconnectPlayer = configured && playerAttached
        plan.startEngine = !engineRunning || needsRebuild
        return plan
    }
}
