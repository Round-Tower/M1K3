//
//  SpeechProvider.swift
//  M1K3Voice
//
//  The TTS seam. AVSpeechProvider (Apple, native, zero-dep) backs the MVP; a
//  KokoroSpeechProvider bridging M1K3's existing Python Kokoro engine swaps in
//  post-MVP — same protocol, so the avatar lip-sync and chat read-aloud don't
//  change. Mirrors the pluggability of InferenceProvider.
//
//  SpeechUtterance is a pure value type (clamped ranges, no AVFoundation), so
//  the request-shaping logic is testable without audio hardware.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-fable-5, 2026-06-11 — added SpeechProviderWithWordTiming
//  (onTimelineReady/onWordSpoken), the karaoke seam. Confidence 0.9.

import Foundation

/// A request to speak text, with normalised prosody. Ranges match AVSpeech's
/// (rate 0…1, pitch 0.5…2.0) but carry no framework dependency — the adapter
/// maps these straight through.
//  Review: Kev + claude-opus-5-5, 2026-10-02 — added SpeechProviderWithPlaybackHealth (stall count). Confidence now 0.85.
//  Review: Kev + claude-opus-5-5, 2026-10-02 (PR #471 round 2) — `stalled(since:)` moved here from the app so
//  `swift test` covers it. Confidence now 0.85.
public struct SpeechUtterance: Sendable, Equatable {
    public static let minRate: Float = 0.0
    public static let maxRate: Float = 1.0
    public static let defaultRate: Float = 0.5
    public static let minPitch: Float = 0.5
    public static let maxPitch: Float = 2.0
    public static let defaultPitch: Float = 1.0

    public let text: String
    public let rate: Float
    public let pitch: Float
    /// Optional platform voice identifier; nil uses the system default voice.
    public let voiceIdentifier: String?

    public init(
        text: String,
        rate: Float = defaultRate,
        pitch: Float = defaultPitch,
        voiceIdentifier: String? = nil
    ) {
        self.text = text
        self.rate = min(max(rate, Self.minRate), Self.maxRate)
        self.pitch = min(max(pitch, Self.minPitch), Self.maxPitch)
        self.voiceIdentifier = voiceIdentifier
    }
}

public protocol SpeechProvider: Sendable {
    /// Stable identifier for routing/UI.
    var name: String { get }
    /// Whether the backend can speak right now.
    var isAvailable: Bool { get }
    /// Enqueue an utterance for speech.
    ///
    /// Completion semantics are implementation-defined: an implementation MAY return
    /// as soon as speech is enqueued (fire-and-forget, e.g. `AVSpeechProvider`) or
    /// only after audio finishes (e.g. `EffectfulSpeechProvider`). Callers MUST NOT
    /// assume audio has finished when this returns — observe `onSpeakingEnded`
    /// (`SpeechProviderWithLifecycle`) to react to actual completion.
    func speak(_ utterance: SpeechUtterance) async
    /// Stop any in-progress and queued speech immediately.
    func stop() async
    /// Whether speech is currently playing.
    func isSpeaking() async -> Bool
}

public extension SpeechProvider {
    /// Convenience: speak plain text with default prosody.
    func speak(_ text: String) async {
        await speak(SpeechUtterance(text: text))
    }
}

/// A speech backend that reports when synthesis starts and stops. The avatar's
/// speaking-state animation hangs off these. Class-bound so a façade
/// (SwappableSpeechProvider) can re-apply the callbacks onto whichever concrete
/// provider is active after a tier swap.
public protocol SpeechProviderWithLifecycle: SpeechProvider, AnyObject {
    /// Invoked on the main thread when synthesis begins.
    var onSpeakingStarted: (@Sendable () -> Void)? { get set }
    /// Invoked on the main thread when synthesis finishes or is stopped.
    var onSpeakingEnded: (@Sendable () -> Void)? { get set }
}

/// A speech backend that can report that audio it scheduled never actually played
/// (a wedged audio engine — live 2026-10-02). Monotonic; callers sample it around
/// an utterance and treat an increase as "not spoken", so a wait-for-speech API
/// can't report success for a line that was silent.
public protocol SpeechProviderWithPlaybackHealth: SpeechProvider {
    var playbackStallCount: Int { get }
}

public extension SpeechProviderWithPlaybackHealth {
    /// Whether the line spoken since `stallsBefore` was sampled did NOT play: the
    /// count rose. The count is per PROVIDER, not per utterance, so a stall from
    /// another speaker inside the window reads as "not spoken" too (false positive),
    /// and an unwaited `speak` can't be checked at all. Callers serialise speech
    /// (the single-flight gate / visitor queue), which keeps the window honest.
    func stalled(since stallsBefore: Int) -> Bool {
        playbackStallCount > stallsBefore
    }
}

/// A speech backend that can additionally report WORD-level timing — the seam
/// the karaoke reading view hangs off. Push-based because the Built-in tier is
/// irreducibly push (AVSpeech delegate events); a separate sub-protocol so
/// existing conformers and test fakes compile untouched.
public protocol SpeechProviderWithWordTiming: SpeechProviderWithLifecycle {
    /// The utterance's timeline as soon as (and whenever) it is known — grows
    /// per synthesized chunk on the Kokoro path; fires once on the Apple
    /// offline-render path; never fires on the live Built-in path (no
    /// durations exist up-front there — only `onWordSpoken` does). Main thread.
    /// When a timeline exists the UI must display `timeline.text` — ranges are
    /// meaningless against any other string.
    var onTimelineReady: (@Sendable (SpokenWordTimeline) -> Void)? { get set }
    /// The word currently being heard, as UTF-16 offsets into the utterance
    /// text. Fires on word CHANGE (~3/s), on the main thread.
    var onWordSpoken: (@Sendable (Range<Int>) -> Void)? { get set }
}
