//
//  TranscriptionProvider.swift
//  M1K3Voice
//
//  The live-dictation seam. Mirrors SpeechProvider (TTS) and InferenceProvider:
//  a thin, swappable adapter identified by `name` + `isAvailable`. Apple Speech
//  (system framework, zero-dep) and WhisperKit (heavy, isolated in its own
//  target) both conform, so the chat voice button doesn't care which engine runs.
//
//  Streaming contract: `startListening()` begins a session and returns a stream
//  of `TranscriptSegment`s — partials as the user speaks, then a final segment.
//  The stream finishes when `stopListening()` is called or recognition ends.
//  One active session per provider; the provider owns the mic/engine lifecycle.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.85,
//  Prior: internal call-pipeline project, TranscriptionProvider (Kev) — generalised to a live
//  session API (the prior call-pipeline's is buffer-pump + call-domain), PerformanceMonitor and
//  PowerEfficiency dropped as MVP-irrelevant.

import Foundation

public protocol TranscriptionProvider: Sendable {
    /// Stable identifier for routing/UI.
    var name: String { get }
    /// Whether this recogniser can run right now (permissions, model, hardware).
    var isAvailable: Bool { get }
    /// Begin a live dictation session, streaming partial then final segments.
    /// Throws if the session can't start (e.g. mic/permission failure).
    func startListening() throws -> AsyncStream<TranscriptSegment>
    /// Begin a live session with an explicit finality policy (see
    /// FinalityPolicy): `.keepsListening` makes recognizer-initiated finality a
    /// segment boundary rather than the end of the listen, so the CONSUMER's
    /// endpointer owns the turn. A protocol REQUIREMENT (not an extension-only
    /// method) so the concrete transcriber's implementation is reached through
    /// `any TranscriptionProvider` — extension-only methods dispatch statically
    /// and would silently pin every caller to the default. The default forwards
    /// to `startListening()`, which is correct for providers whose finality
    /// only ever comes from a consumer stop (WhisperKit).
    func startListening(finality: FinalityPolicy) throws -> AsyncStream<TranscriptSegment>
    /// Stop the active session; flushes a final segment then finishes the stream.
    func stopListening()

    /// Whether this recogniser drives a mic path we can put Apple's voice
    /// processing on — acoustic echo cancellation, noise suppression, and
    /// speech-triggered ducking of other audio.
    ///
    /// It reports the ATTEMPT, not a guarantee: voice processing is unavailable on
    /// some aggregate/virtual input devices and fails softly there (see
    /// `AppleSpeechTranscriber.enableVoiceProcessing`). Named honestly so nobody
    /// reads it as "echo is definitely cancelled".
    ///
    /// This exists because the two engines are NOT interchangeable here. WhisperKit
    /// builds its own `AVAudioEngine` inside the package (`setupEngine` and
    /// `processBuffer` are both internal), so there is no seam from out here to
    /// enable voice processing on it — verified against the checkout, 2026-08-11.
    /// A conversation held over speakers with music playing therefore has to pick:
    /// the sharper transcriber, or the one that can keep the room out of the mic.
    var attemptsEchoCancellation: Bool { get }
}

public extension TranscriptionProvider {
    /// Default: the finality policy is ignored and the plain session starts —
    /// correct for providers that only ever finalize on a consumer stop
    /// (WhisperKit), where the two policies are indistinguishable.
    func startListening(finality _: FinalityPolicy) throws -> AsyncStream<TranscriptSegment> {
        try startListening()
    }

    /// Default false: a provider must opt IN to claiming echo cancellation, so a
    /// new backend can never silently inherit a promise it doesn't keep.
    var attemptsEchoCancellation: Bool {
        false
    }
}
