//
//  PlaybackStallStreak.swift
//  M1K3Voice
//
//  When to stop trusting the AVAudioEngine path and speak through the plain
//  AVSpeech fallback instead. Pure value type so `swift test` pins it; the glue
//  that consults it (EffectfulSpeechProvider) is verify-by-launch.
//
//  Why (live 2026-10-02): a rebuild after a stalled deadline only helps if the
//  fresh engine is healthy. `maximumFramesToRender` is best-effort, so on a device
//  that still fails every render each utterance would burn duration + grace and
//  then be dropped — M1K3 silent for as long as the device stays odd.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-02, Confidence 0.75, Prior: Unknown
//  Open: threshold 2 and probe interval 5 are judgements, not measurements.

/// Consecutive deadline stalls → route to the plain voice, with a periodic probe
/// so the engine path can win its place back without an app restart.
///
/// - Threshold 2: the first stall is the case the rebuild is FOR (a route settle, a
///   grown IO buffer), so the next utterance gets the rebuilt engine as its retry.
///   A second consecutive stall means the rebuild did not take; a third would cost
///   another duration + 3 s of silence for nothing.
/// - Probe every 5th utterance while in fallback: the live failure persisted across
///   a route flip back to the built-in speakers with NO configuration change, so
///   "wait for the next route change" is not enough to recover. One probe costs at
///   most one more stalled utterance; a success resets everything.
struct PlaybackStallStreak: Equatable {
    enum Route: Equatable {
        case engine
        case plain
    }

    static let fallbackThreshold = 2
    static let probeInterval = 5

    private(set) var consecutiveStalls = 0
    private(set) var plainUtterancesSinceStall = 0

    /// Where the next utterance would go. Does not advance the probe cycle, so
    /// several code paths may ask about the SAME utterance.
    var route: Route {
        if consecutiveStalls < Self.fallbackThreshold { return .engine }
        return plainUtterancesSinceStall >= Self.probeInterval - 1 ? .engine : .plain
    }

    /// Decide for one utterance and advance the probe cycle when it goes plain.
    mutating func consumeRoute() -> Route {
        let decided = route
        if decided == .plain { plainUtterancesSinceStall += 1 }
        return decided
    }

    mutating func recordStall() {
        consecutiveStalls += 1
        plainUtterancesSinceStall = 0
    }

    /// Audio actually played back through the engine.
    mutating func recordSuccess() {
        self = PlaybackStallStreak()
    }

    /// A fresh route / engine configuration deserves a clean slate.
    mutating func reset() {
        self = PlaybackStallStreak()
    }
}
