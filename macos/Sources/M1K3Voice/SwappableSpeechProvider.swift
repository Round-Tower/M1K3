//
//  SwappableSpeechProvider.swift
//  M1K3Voice
//
//  A SpeechProvider façade whose backing engine can change at runtime, so
//  switching the chosen voice tier (Built-in AVSpeech ↔ M1K3 Voice / Kokoro)
//  re-points TTS without rebuilding the AppEnvironment callers that hold it.
//  Mirrors SwappableInferenceProvider / SwappableEmbeddingService.
//
//  It also owns the canonical onSpeakingStarted/Ended callbacks (which drive the
//  avatar's speaking animation) and re-applies them onto whichever concrete
//  provider is active after a swap — so the avatar keeps reacting across a tier
//  change without the caller re-wiring anything.
//
//  Signed: Kev + claude-sonnet-4-6, 2026-06-08, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-fable-5, 2026-06-11 — stores + re-applies the word-timing
//  callbacks on swap, same pattern as lifecycle. Confidence 0.9.
//  Review: Kev + claude-opus-5-5, 2026-10-02 — forwards playbackStallCount (SpeechProviderWithPlaybackHealth)
//  so the MCP speak(wait:) layer can tell a stalled engine from a spoken line. Confidence now 0.85.
//  Review: Kev + claude-opus-5-5, 2026-10-02 (PR #471 round 2) — playbackStallCount is monotonic across tier
//  swaps (a base offset re-seated at each swap), so `> stallsBefore` can't miss a stall. Residual: a stall on
//  the OUTGOING tier after a mid-utterance swap is not seen. Confidence now 0.85.

import Foundation
import Synchronization

public final class SwappableSpeechProvider: SpeechProviderWithWordTiming, SpeechProviderWithPlaybackHealth, Sendable {
    public let name = "swappable-speech"

    private struct State {
        var current: any SpeechProvider
        var startedCallback: (@Sendable () -> Void)?
        var endedCallback: (@Sendable () -> Void)?
        var timelineCallback: (@Sendable (SpokenWordTimeline) -> Void)?
        var wordCallback: (@Sendable (Range<Int>) -> Void)?
        /// Added to the active tier's own count so the façade's total never drops
        /// when a tier with a smaller count swaps in (see `setProvider`).
        var stallBase = 0
    }

    private let state: Mutex<State>

    public init(_ initial: any SpeechProvider) {
        state = Mutex(State(current: initial))
    }

    /// The currently-active backend.
    public var active: any SpeechProvider {
        state.withLock { $0.current }
    }

    /// Swap the backing engine. The lifecycle callbacks are re-applied to the new
    /// provider so the avatar keeps reacting to speech after the swap.
    public func setProvider(_ provider: any SpeechProvider) {
        state.withLock {
            // Re-seat the base so the total is continuous across the swap: the
            // outgoing tier's count is folded in, the incoming tier's is netted out.
            let outgoing = ($0.current as? SpeechProviderWithPlaybackHealth)?.playbackStallCount ?? 0
            let incoming = (provider as? SpeechProviderWithPlaybackHealth)?.playbackStallCount ?? 0
            $0.stallBase += outgoing - incoming
            $0.current = provider
            Self.applyCallbacks(to: &$0)
        }
    }

    public var onSpeakingStarted: (@Sendable () -> Void)? {
        get { state.withLock { $0.startedCallback } }
        set { state.withLock { $0.startedCallback = newValue; Self.applyCallbacks(to: &$0) } }
    }

    public var onSpeakingEnded: (@Sendable () -> Void)? {
        get { state.withLock { $0.endedCallback } }
        set { state.withLock { $0.endedCallback = newValue; Self.applyCallbacks(to: &$0) } }
    }

    public var onTimelineReady: (@Sendable (SpokenWordTimeline) -> Void)? {
        get { state.withLock { $0.timelineCallback } }
        set { state.withLock { $0.timelineCallback = newValue; Self.applyCallbacks(to: &$0) } }
    }

    public var onWordSpoken: (@Sendable (Range<Int>) -> Void)? {
        get { state.withLock { $0.wordCallback } }
        set { state.withLock { $0.wordCallback = newValue; Self.applyCallbacks(to: &$0) } }
    }

    /// Forward the stored callbacks onto the active provider if it reports
    /// lifecycle (and word timing — a lifecycle-only tier simply never emits
    /// timing, so the karaoke view stays inert there). Caller must hold the lock.
    private static func applyCallbacks(to state: inout State) {
        if let lifecycle = state.current as? SpeechProviderWithLifecycle {
            lifecycle.onSpeakingStarted = state.startedCallback
            lifecycle.onSpeakingEnded = state.endedCallback
        }
        if let timing = state.current as? SpeechProviderWithWordTiming {
            timing.onTimelineReady = state.timelineCallback
            timing.onWordSpoken = state.wordCallback
        }
    }

    public var isAvailable: Bool {
        active.isAvailable
    }

    /// The active tier's stall count plus the base carried across swaps — monotonic
    /// (0 contribution from a tier that cannot stall).
    public var playbackStallCount: Int {
        state.withLock { state in
            state.stallBase + ((state.current as? SpeechProviderWithPlaybackHealth)?.playbackStallCount ?? 0)
        }
    }

    public func speak(_ utterance: SpeechUtterance) async {
        await active.speak(utterance)
    }

    public func stop() async {
        await active.stop()
    }

    public func isSpeaking() async -> Bool {
        await active.isSpeaking()
    }
}
