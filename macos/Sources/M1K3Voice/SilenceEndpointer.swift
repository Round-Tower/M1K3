//
//  SilenceEndpointer.swift
//  M1K3Voice
//
//  Closes the recognizer-finality gap for the voice loop: live recognizers can
//  sit on a finished utterance for seconds before declaring isFinal, which
//  reads as M1K3 ignoring you. A non-empty partial that stops CHANGING for the
//  silence threshold is the user being done — the driver polls this and ends
//  the listen itself.
//
//  The threshold must exceed the recognizer's partial-emission cadence
//  (WhisperKit hops ~1 s windows, re-emitting identical text) or it would
//  endpoint mid-sentence — hence the ~1.6 s default; tune live.
//
//  Completeness-aware: when the stable partial trails off mid-thought (a dangling
//  conjunction/preposition/filler — see UtteranceCompleteness), the endpointer
//  waits the longer `holdSilence` before ending, so a natural pause inside a
//  multi-clause utterance ("tell me about the" <pause> "weather") no longer
//  fragments it into half-thoughts the model then reasons over incorrectly. A
//  `maxWait` from first speech is the anti-hang backstop for a partial that never
//  stabilises (a stuck/hallucinating recognizer).
//
//  CADENCE-ADAPTIVE (2026-08-11): a fixed threshold has now been raised twice on
//  the same complaint ("it cuts me off mid-thought" — Kev, 2026-07-29 and
//  2026-08-06), which is the signal that the knob is the wrong shape. A pause is
//  not a property of the language, it's a property of the SPEAKER: some people
//  finish a clause and stop, some finish a clause and think. So the endpointer
//  now LEARNS. Every intra-utterance pause the speaker demonstrably recovered
//  from — they went quiet past the endpoint threshold and then carried on —
//  raises a floor under all later waits (`observedPause` + `cadenceMargin`,
//  clamped at `cadenceCeiling`). It only ever learns from evidence of a longer
//  rhythm, which is why it can't be gamed by ordinary word-by-word growth, and
//  the floor is capped so one long silence can't stall the loop.
//
//  The point of adapting rather than just waiting longer is the double bind: Kev
//  wants BOTH "stop clipping me" and "voice-first is slow". A flat +2s taxes
//  every crisp reply to protect the deliberate ones; a learned floor charges
//  only the speakers who have actually shown they pause.
//
//  Signed: Kev + claude-fable-5, 2026-06-11, Confidence 0.85 (pure, test-pinned;
//  the default thresholds are empirical starting points). Prior: Unknown.
//  Review: Kev + claude-opus-4-8, 2026-06-17 — added completeness-aware hold +
//  maxWait backstop to stop utterance fragmentation. Confidence 0.85.
//  Review: Kev + claude-opus-5, 2026-08-11 — cadence adaptation (above). The
//  learned pause deliberately SURVIVES reset(): it belongs to the speaker, not
//  the utterance, so turn two of a session is not clipped the way turn one was.
//  `resetCadence()` is the session boundary. Confidence 0.85 — pure and
//  test-pinned, but the margin/ceiling defaults are judgement, not measurement,
//  and only Kev's ear can settle them.
//  Review: Kev + claude-fable-5, 2026-08-15 — decision(at:) added: the same
//  branches, now returning a reason-carrying EndpointDecision the controller
//  logs; shouldEndpoint is exactly `decision != nil` (test-pinned). Behaviour
//  unchanged by construction. Confidence 0.9.
//

import Foundation

public struct SilenceEndpointer: Sendable {
    private let silence: Duration
    private let holdSilence: Duration
    private let maxWait: Duration
    private let cadenceMargin: Duration
    private let cadenceCeiling: Duration
    private let politeSilence: Duration
    private var lastText = ""
    private var lastChange: ContinuousClock.Instant?
    /// When the partial first became non-empty (first RECOGNISED speech, which can
    /// lag mic-open by ~1s on WhisperKit) — the anchor for `maxWait`.
    private var firstSpeech: ContinuousClock.Instant?
    /// The longest pause this speaker has demonstrably spoken THROUGH (went quiet
    /// past `silence`, then carried on), clamped to `cadenceCeiling`. Survives
    /// `reset()` — it describes the speaker, not the utterance.
    private var learnedPause: Duration = .zero

    /// - Parameters:
    ///   - silence: idle gap that ends a listen when the partial reads complete.
    ///   - holdSilence: the longer gap allowed when the partial trails off
    ///     mid-thought, so a natural pause doesn't fragment the utterance.
    ///   - maxWait: hard cap from first speech so a never-stabilising partial
    ///     (stuck recognizer) still endpoints rather than hanging.
    ///   - cadenceMargin: headroom added to the longest pause this speaker has
    ///     been observed to speak through, so we wait a beat longer than their
    ///     own worst-case rhythm rather than exactly as long.
    ///   - cadenceCeiling: hard clamp on the learned floor, so one long silence
    ///     can never stall the loop. `.zero` disables adaptation entirely
    ///     (the fixed-threshold behaviour, useful for isolating tests).
    ///
    /// The two cadence defaults are READ from `EndpointCadence.conversational`
    /// rather than retyped, because a knob written down twice is how the Mac and
    /// iOS timings drifted in the first place. The `silence`/`holdSilence`/
    /// `maxWait` defaults deliberately do NOT follow suit: they're the older fixed
    /// thresholds that existing tests pin, and production reaches this init only
    /// through the preset.
    public init(
        silence: Duration = .seconds(1.6),
        holdSilence: Duration = .seconds(3.0),
        maxWait: Duration = .seconds(20),
        cadenceMargin: Duration = EndpointCadence.conversational.cadenceMargin,
        cadenceCeiling: Duration = EndpointCadence.conversational.cadenceCeiling,
        politeSilence: Duration = EndpointCadence.conversational.polite
    ) {
        // Duration interpolates with its SI suffix, e.g. "3.0 s" / "1.5 s".
        precondition(
            holdSilence >= silence,
            "holdSilence (\(holdSilence)) must be ≥ silence (\(silence)) to extend the listen "
                + "window — a shorter hold would endpoint incomplete partials FASTER than "
                + "complete ones, inverting the intent."
        )
        self.silence = silence
        self.holdSilence = holdSilence
        self.maxWait = maxWait
        self.cadenceMargin = cadenceMargin
        self.cadenceCeiling = cadenceCeiling
        self.politeSilence = politeSilence
    }

    /// The longest pause this speaker has been observed to speak THROUGH. Exposed
    /// for the loop's log line — how long M1K3 has learned to wait is exactly the
    /// thing you want in the trail when someone reports being clipped.
    public var observedPause: Duration {
        learnedPause
    }

    /// Feed every partial as it arrives. Identical re-emissions (recognizer
    /// window hops) do NOT reset the clock — only actual text change does. (A
    /// non-empty partial always stamps `lastChange` on the change that set it, so
    /// there's no separate "first identical emission" branch to handle.)
    public mutating func ingest(partial: String, at instant: ContinuousClock.Instant) {
        guard partial != lastText else { return }
        learnCadence(resumingAt: instant)
        lastText = partial
        lastChange = instant
        if firstSpeech == nil, !partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            firstSpeech = instant
        }
    }

    /// New text arrived — if the speaker had gone quiet for longer than the
    /// endpoint threshold and then carried on, that gap is their rhythm, and we
    /// remember it. Two guards keep it honest:
    ///   • the PREVIOUS text must be non-empty, or we'd learn mic-open/recognizer
    ///     warm-up latency (a WhisperKit listen can sit empty for seconds) as if
    ///     it were the user thinking;
    ///   • the gap must reach `silence`, or ordinary word-by-word partial growth
    ///     would ratchet every speaker toward the ceiling.
    private mutating func learnCadence(resumingAt instant: ContinuousClock.Instant) {
        guard let lastChange,
              !lastText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let gap = lastChange.duration(to: instant)
        guard gap >= silence else { return }
        learnedPause = max(learnedPause, min(gap, cadenceCeiling))
    }

    /// True once a non-empty partial has gone idle for long enough — the normal
    /// `silence` when it reads complete, the longer `holdSilence` when it trails
    /// off mid-thought — or once `maxWait` from first speech is hit (anti-hang).
    /// Exactly `decision(at:) != nil`, pinned by test — the decision carries the
    /// reason and thresholds for the log.
    public func shouldEndpoint(at now: ContinuousClock.Instant) -> Bool {
        decision(at: now) != nil
    }

    /// The reason-carrying endpoint check (see EndpointDecision): nil while the
    /// listen should continue, otherwise which branch fired, the idle gap, and
    /// the threshold that applied.
    public func decision(at now: ContinuousClock.Instant) -> EndpointDecision? {
        guard let lastChange, !lastText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        let idle = lastChange.duration(to: now)
        // Anti-hang backstop: once we've been going past maxWait AND the recognizer
        // has actually gone quiet (idle ≥ silence), end it — but never cut a user
        // who's still actively speaking (partials still advancing).
        if let firstSpeech, firstSpeech.duration(to: now) >= maxWait, idle >= silence {
            return EndpointDecision(reason: .maxWait, idle: idle, required: silence)
        }
        // The polite fast-path: a turn ending on "please" is the spoken submit
        // button — it bypasses the completeness hold AND the learned cadence
        // floor, because the user has TOLD us they're done (see PoliteEndpoint).
        // `politeSilence` still applies so a recognizer partial that merely
        // paused on "please tell me…" has one hop's grace to continue.
        if PoliteEndpoint.isSubmit(lastText), idle >= politeSilence {
            return EndpointDecision(reason: .politeWord, idle: idle, required: politeSilence)
        }
        let complete = UtteranceCompleteness.looksComplete(lastText)
        let base = complete ? silence : holdSilence
        // The learned floor lifts BOTH thresholds: a speaker who pauses 3s inside
        // a thought does it after complete-sounding clauses too, which is exactly
        // the clip being reported. Only the learned component is clamped — never
        // `base`, or a low ceiling would silently SHORTEN a configured hold.
        let needed = max(base, min(learnedPause + cadenceMargin, cadenceCeiling))
        guard idle >= needed else { return nil }
        return EndpointDecision(
            reason: complete ? .completeThought : .midThoughtHold,
            idle: idle,
            required: needed
        )
    }

    /// Clear for the next listen. Deliberately KEEPS the learned cadence: the
    /// speaker's rhythm carries across turns, so turn two isn't clipped the way
    /// turn one was. The session boundary is the endpointer's own lifetime — the
    /// voice loop builds a fresh one per voice-mode entry, so nothing needs (or
    /// gets) an explicit "forget the speaker" call.
    public mutating func reset() {
        lastText = ""
        lastChange = nil
        firstSpeech = nil
    }
}
