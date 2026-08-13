//
//  EndpointCadence.swift
//  M1K3Voice
//
//  The conversational endpointing settings, in ONE place. They used to be typed
//  literally into each shell's enterVoiceMode — and promptly drifted: the Mac ran
//  2.0/4.5/30 (2026-08-06) while iOS ran 2.0/3.5/20 (2026-07-29), from the SAME
//  complaint on both. Two copies of a tuning knob means the next fix lands on one
//  surface and the other keeps clipping you.
//
//  The numbers are Kev's ear, and it's the third pass over them ("allow for a bit
//  of time, there's a lot of space between" — 2026-08-11). What changed this time
//  is that they're now a FLOOR, not the whole story: SilenceEndpointer learns the
//  speaker's own rhythm on top (see its header), so these values only have to be
//  right for the first pause of a session.
//
//  Signed: Kev + claude-opus-5, 2026-08-11, Confidence 0.8 (the invariants and the
//  single-source-of-truth are pinned; the specific durations are judgement from a
//  live complaint, and the felt beat is Kev's to settle at ⌘R). Prior: the two
//  divergent literals in AppEnvironment+VoiceMode.swift and AppCore+Voice.swift.
//

import Foundation

/// How patient the voice loop is with a pause. One preset, both shells.
public struct EndpointCadence: Sendable, Equatable {
    /// Idle gap that ends a listen when the partial reads like a finished thought.
    public let silence: Duration
    /// The longer gap allowed when the partial trails off mid-thought.
    public let hold: Duration
    /// Anti-hang cap from first speech (a stuck/hallucinating recognizer).
    public let maxWait: Duration
    /// Headroom over the speaker's own observed worst-case pause.
    public let cadenceMargin: Duration
    /// Clamp on the learned floor, so one long silence can't stall the loop.
    public let cadenceCeiling: Duration
    /// The short window after a trailing "please" — the spoken submit button
    /// (see PoliteEndpoint). Must exceed the slowest recognizer's partial
    /// cadence (WhisperKit hops ~1s windows) or "please tell me…" could be
    /// clipped to "please" before the continuation ever arrives.
    public let polite: Duration

    public init(
        silence: Duration,
        hold: Duration,
        maxWait: Duration,
        cadenceMargin: Duration,
        cadenceCeiling: Duration,
        polite: Duration = .seconds(1.0)
    ) {
        self.silence = silence
        self.hold = hold
        self.maxWait = maxWait
        self.cadenceMargin = cadenceMargin
        self.cadenceCeiling = cadenceCeiling
        self.polite = polite
    }

    /// Human conversation, not command dictation: a complete-sounding sentence
    /// turns over at 2.5s, a trailed-off one gets 5s to breathe, and a speaker who
    /// shows a longer rhythm is granted up to 6s before M1K3 takes its turn.
    ///
    /// Every value here is paid AFTER the user stops talking, so it is felt
    /// latency — which is why the ceiling exists and why the adaptive floor is
    /// preferred over simply raising `silence` for everyone.
    public static let conversational = EndpointCadence(
        silence: .seconds(2.5),
        hold: .seconds(5.0),
        maxWait: .seconds(30),
        cadenceMargin: .seconds(0.75),
        cadenceCeiling: .seconds(6.0)
    )
}
