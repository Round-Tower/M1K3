//
//  AVSpeechProvider.swift
//  M1K3Voice
//
//  Native TTS via AVSpeechSynthesizer (AVFoundation — ships with macOS, no
//  third-party dependency). The MVP voice. Thin OS adapter: the synthesizer is
//  touched only on the main actor, so the @unchecked Sendable is sound. The
//  testable shaping lives in SpeechUtterance; this file is verified by name +
//  conformance, not by emitting audio.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.8, Prior: Unknown
//  Review: claude-opus-4-8, 2026-06-09 (PR #10) — lock the callback properties.
//  They're read from `nonisolated` delegate methods and written on a provider swap
//  (SwappableSpeechProvider); even though AVFoundation delivers on the main queue,
//  a torn read across the @unchecked surface is now ruled out by an NSLock.
//  Review: Kev + claude-fable-5, 2026-06-11 — adopted SpeechProviderWithWordTiming:
//  willSpeakRangeOfSpeechString → onWordSpoken (exact live word ranges).
//  Confidence 0.85.
//  Review: Kev + claude-fable-5.1, 2026-10-13 — `defaultVoiceIdentifier` (#584): the voice an utterance
//  that names none speaks in. The shells set it once at launch from `BestSystemVoice.pick`, so Built-in
//  is the best installed voice, never the compact default when a better one exists. Confidence 0.85.

import AVFoundation
import Foundation

public final class AVSpeechProvider: NSObject, SpeechProviderWithWordTiming, @unchecked Sendable {
    public let name = "av-speech"

    private let synthesizer = AVSpeechSynthesizer()

    private let callbackLock = NSLock()
    private var _onSpeakingStarted: (@Sendable () -> Void)?
    private var _onSpeakingEnded: (@Sendable () -> Void)?
    private var _onTimelineReady: (@Sendable (SpokenWordTimeline) -> Void)?
    private var _onWordSpoken: (@Sendable (Range<Int>) -> Void)?
    private var _defaultVoiceIdentifier: String?

    /// The voice for utterances that name none; nil keeps the system default.
    /// Resolved once at launch by the shells (`BestSystemVoice`). Lock-guarded
    /// like the callbacks: written on the main actor, read in `speak`.
    public var defaultVoiceIdentifier: String? {
        get { callbackLock.withLock { _defaultVoiceIdentifier } }
        set { callbackLock.withLock { _defaultVoiceIdentifier = newValue } }
    }

    /// Called on the main thread when synthesis starts. Set by AppEnvironment to
    /// drive the avatar into the .speaking activity state. Lock-guarded: read from
    /// the `nonisolated` delegate, written on a provider swap.
    public var onSpeakingStarted: (@Sendable () -> Void)? {
        get { callbackLock.withLock { _onSpeakingStarted } }
        set { callbackLock.withLock { _onSpeakingStarted = newValue } }
    }

    /// Called on the main thread when synthesis finishes or is stopped. Lock-guarded
    /// for the same reason as `onSpeakingStarted`.
    public var onSpeakingEnded: (@Sendable () -> Void)? {
        get { callbackLock.withLock { _onSpeakingEnded } }
        set { callbackLock.withLock { _onSpeakingEnded = newValue } }
    }

    /// Never fires on this live path — AVSpeech exposes no durations up-front,
    /// only the as-it-speaks word ranges below. Stored so the façade can still
    /// forward it uniformly.
    public var onTimelineReady: (@Sendable (SpokenWordTimeline) -> Void)? {
        get { callbackLock.withLock { _onTimelineReady } }
        set { callbackLock.withLock { _onTimelineReady = newValue } }
    }

    /// Exact word timing for free: AVSpeech announces each word as it speaks it
    /// (willSpeakRangeOfSpeechString). Lock-guarded like the lifecycle pair.
    public var onWordSpoken: (@Sendable (Range<Int>) -> Void)? {
        get { callbackLock.withLock { _onWordSpoken } }
        set { callbackLock.withLock { _onWordSpoken = newValue } }
    }

    override public init() {
        super.init()
        synthesizer.delegate = self
    }

    public nonisolated var isAvailable: Bool {
        true
    }

    public func speak(_ utterance: SpeechUtterance) async {
        await MainActor.run {
            let spoken = AVSpeechUtterance(string: utterance.text)
            spoken.rate = utterance.rate
            spoken.pitchMultiplier = utterance.pitch
            if let id = utterance.voiceIdentifier ?? defaultVoiceIdentifier,
               let voice = AVSpeechSynthesisVoice(identifier: id)
            {
                spoken.voice = voice
            }
            synthesizer.speak(spoken)
        }
    }

    public func stop() async {
        await MainActor.run {
            _ = synthesizer.stopSpeaking(at: .immediate)
        }
    }

    public func isSpeaking() async -> Bool {
        await MainActor.run { synthesizer.isSpeaking }
    }
}

// MARK: - AVSpeechSynthesizerDelegate

// Delegate methods are delivered on the main queue by AVFoundation.

extension AVSpeechProvider: AVSpeechSynthesizerDelegate {
    public nonisolated func speechSynthesizer(
        _: AVSpeechSynthesizer,
        didStart _: AVSpeechUtterance
    ) {
        let callback = onSpeakingStarted
        Task { @MainActor in callback?() }
    }

    public nonisolated func speechSynthesizer(
        _: AVSpeechSynthesizer,
        didFinish _: AVSpeechUtterance
    ) {
        let callback = onSpeakingEnded
        Task { @MainActor in callback?() }
    }

    public nonisolated func speechSynthesizer(
        _: AVSpeechSynthesizer,
        didCancel _: AVSpeechUtterance
    ) {
        let callback = onSpeakingEnded
        Task { @MainActor in callback?() }
    }

    public nonisolated func speechSynthesizer(
        _: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance _: AVSpeechUtterance
    ) {
        let callback = onWordSpoken
        let range = characterRange.location ..< characterRange.location + characterRange.length
        Task { @MainActor in callback?(range) }
    }
}
