//
//  VoiceTurnTimeline.swift
//  M1K3Voice
//
//  What a voice turn actually costs, in the four numbers you'd need to make it
//  faster — and nowhere else in the app were they written down.
//
//  Per-generation timings existed (`ttft`: prefill ms, decode tok/s) but a voice
//  turn is not one generation: it is retrieval + a grounding cap + an agent loop
//  that may run several generations, and only then a synthesiser. So "the model
//  did 30 tok/s" never answered the question the user is actually asking, which
//  is *how long after I stopped talking did M1K3 start talking back*. This is
//  the envelope around all of it:
//
//    endpointed ──▶ turn ──▶ first speakable sentence ──▶ first audio ──▶ done
//                           └─────── reply ───────┘└── synth ──┘
//
//  Pure and clock-injected: every mark takes its instant from the caller, so the
//  arithmetic is pinned by tests with no sleeping and no tolerance windows. The
//  controller owns one of these per turn and logs `summary()` when the turn
//  settles.
//
//  Two deliberate shapes, both learned here:
//  • FIRST chunk and FIRST audio win their marks. The later ones only increment
//    the count — a five-sentence answer must not overwrite the number that
//    describes how quickly it started.
//  • An unfinished turn still reports. A barge-in mid-answer is exactly the turn
//    whose latency you most want to see, and dropping it would bias every
//    measurement towards the turns the user was patient enough to sit through.
//
//  Signed: Kev + claude-opus-5, 2026-08-13, Confidence 0.9 (pure arithmetic,
//  red-first; what the marks are wired to in the controller is verify-by-launch).
//  Prior: Unknown.
//

import Foundation

/// One voice turn's latency envelope, from the moment the speaker stopped to the
/// moment M1K3 finished generating.
public struct VoiceTurnTimeline: Sendable, Equatable {
    private var endpointedAt: ContinuousClock.Instant?
    private var turnStartedAt: ContinuousClock.Instant?
    private var firstChunkAt: ContinuousClock.Instant?
    private var firstAudioAt: ContinuousClock.Instant?
    private var completedAt: ContinuousClock.Instant?
    private var chunks = 0

    public init() {}

    /// The speaker stopped — the instant the user starts counting from.
    public mutating func endpointed(at instant: ContinuousClock.Instant) {
        endpointedAt = instant
    }

    /// The turn was handed to the responder.
    public mutating func turnStarted(at instant: ContinuousClock.Instant) {
        turnStartedAt = instant
    }

    /// A speakable sentence folded out of the stream. First one wins the mark;
    /// the rest are counted.
    public mutating func chunkReady(at instant: ContinuousClock.Instant) {
        chunks += 1
        if firstChunkAt == nil { firstChunkAt = instant }
    }

    /// Audio actually began playing (the TTS provider's started callback).
    ///
    /// Ignored while no sentence exists: speech is only ever enqueued after a
    /// chunk, so a started-callback with no chunk behind it is a stale tail
    /// from a previous (barged-in) turn arriving after the flush — recording
    /// it would hand this turn a bogus "first audio" that first-wins then
    /// keeps, and settle the turn before it has actually spoken. (A stale
    /// callback arriving AFTER this turn's first chunk is not distinguishable
    /// without utterance identity from the provider; that window is the synth
    /// gap, ~centiseconds, and is accepted.)
    public mutating func audioStarted(at instant: ContinuousClock.Instant) {
        guard firstChunkAt != nil else { return }
        if firstAudioAt == nil { firstAudioAt = instant }
    }

    /// Generation finished (not playback — the answer is fully in hand).
    public mutating func completed(at instant: ContinuousClock.Instant) {
        completedAt = instant
    }

    /// Drop every mark, ready for the next turn.
    public mutating func reset() {
        self = VoiceTurnTimeline()
    }

    /// A turn has been handed off — there is something worth reporting.
    public var hasTurn: Bool {
        turnStartedAt != nil
    }

    /// Every number this turn can produce has landed, so it can be reported now
    /// rather than held until the next turn displaces it. Generation completing
    /// is NOT enough on its own: in the streaming shape audio starts first, but
    /// in the whole-answer shape it starts last.
    public var isSettled: Bool {
        completedAt != nil && firstAudioAt != nil
    }

    /// Where the user's stopwatch starts. The spoken path has an endpoint; a
    /// typed or programmatic turn doesn't, and measuring that from a nil
    /// baseline would silently read as zero latency.
    private var baseline: ContinuousClock.Instant? {
        endpointedAt ?? turnStartedAt
    }

    /// One line, or nil when no turn ever ran (an endpoint with no turn behind
    /// it is a parked/empty listen and has nothing to say about latency).
    public func summary() -> String? {
        guard turnStartedAt != nil, let baseline else { return nil }
        var parts: [String] = []
        if let firstChunkAt {
            parts.append("first sentence \(Self.ms(baseline.duration(to: firstChunkAt)))ms")
        }
        if let firstAudioAt {
            if let firstChunkAt {
                parts.append("synth \(Self.ms(firstChunkAt.duration(to: firstAudioAt)))ms")
            }
            parts.append("first audio \(Self.ms(baseline.duration(to: firstAudioAt)))ms")
        } else {
            parts.append("no audio")
        }
        if let completedAt {
            parts.append("answer \(Self.ms(baseline.duration(to: completedAt)))ms")
        }
        parts.append("\(chunks) \(chunks == 1 ? "sentence" : "sentences")")
        return "voice turn: " + parts.joined(separator: " · ")
    }

    private static func ms(_ duration: Duration) -> Int {
        duration.wholeMilliseconds
    }
}

public extension Duration {
    /// Whole milliseconds. A negative span (clock marks arriving out of order —
    /// possible if a provider's started-callback races the fold) clamps to 0
    /// rather than printing a nonsense negative.
    var wholeMilliseconds: Int {
        let parts = components
        let value = parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000
        return value > 0 ? Int(value) : 0
    }
}
