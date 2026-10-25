//
//  TurnPhaseTimeline.swift
//  M1K3Chat
//
//  Where a turn's PRE-generation time goes. The 2026-08-10 live-path eval
//  found 177 seconds of total log silence before a turn's first model call —
//  the largest single latency contributor was invisible, because the
//  responder's "turn start:" line only fires AFTER retrieval. These marks
//  cover the stretch the responder owns before any token is generated:
//
//    started ──▶ embedded ──▶ retrieved ──▶ capped ──▶ handedOff
//              └── embed ──┘└─ retrieve ─┘└── cap ──┘   (pre-gen total)
//
//  Pure and clock-injected (the VoiceTurnTimeline precedent): every mark takes
//  its instant from the caller, so the arithmetic is pinned by tests with no
//  sleeping. Skipped phases (a self-query turn never embeds) simply never
//  mark, and the summary omits them. An unfinished turn still reports — the
//  turn that HANGS mid-phase is exactly the one whose marks matter most.
//
//  Signed: Kev + claude-fable-5, 2026-08-16, Confidence 0.9 (pure arithmetic,
//  red-first; the answerStreaming wiring runs on every live turn). Prior: Unknown.
//  Review: Kev + claude-fable-5.1, 2026-10-25 — `firstTokenSummary`: the pre-gen line stopped at
//  hand-off, so a live turn never said when its first token landed. The responder logs it off the
//  stream's first chunk (both spans: from start, from hand-off). Confidence 0.85.
//

import Foundation

/// One turn's pre-generation latency envelope, from responder entry to the
/// moment the stream is handed back to the caller.
public struct TurnPhaseTimeline: Sendable, Equatable {
    /// Which routing branch the turn took — printed so a slow self-query turn
    /// is never misread as a slow retrieval.
    public enum Gate: String, Sendable {
        case normal
        case selfQuery = "self-query"
    }

    private var startedAt: ContinuousClock.Instant?
    private var embeddedAt: ContinuousClock.Instant?
    private var retrievedAt: ContinuousClock.Instant?
    private var cappedAt: ContinuousClock.Instant?
    private var handedOffAt: ContinuousClock.Instant?

    public init() {}

    /// Responder entry — the caller has handed the question over.
    public mutating func started(at instant: ContinuousClock.Instant) {
        startedAt = instant
    }

    /// The query vector is in hand (the embedder — cold-load hides here).
    public mutating func embedded(at instant: ContinuousClock.Instant) {
        embeddedAt = instant
    }

    /// Hybrid search + relevance gate done.
    public mutating func retrieved(at instant: ContinuousClock.Instant) {
        retrievedAt = instant
    }

    /// The grounding token cap has run.
    public mutating func capped(at instant: ContinuousClock.Instant) {
        cappedAt = instant
    }

    /// The stream is handed back — generation begins beyond this point.
    public mutating func handedOff(at instant: ContinuousClock.Instant) {
        handedOffAt = instant
    }

    /// One line, or nil when the turn never started. Each segment is measured
    /// from the previous mark that exists, so skipped phases don't misattribute
    /// their neighbours' time.
    public func summary(gate: Gate) -> String? {
        guard let startedAt else { return nil }
        var parts: [String] = []
        var previous = startedAt
        if let embeddedAt {
            parts.append("embed \(Self.ms(previous.duration(to: embeddedAt)))ms")
            previous = embeddedAt
        }
        if let retrievedAt {
            parts.append("retrieve \(Self.ms(previous.duration(to: retrievedAt)))ms")
            previous = retrievedAt
        }
        if let cappedAt {
            parts.append("cap \(Self.ms(previous.duration(to: cappedAt)))ms")
            previous = cappedAt
        }
        if let handedOffAt {
            parts.append("pre-gen \(Self.ms(startedAt.duration(to: handedOffAt)))ms")
        }
        parts.append("gate=\(gate.rawValue)")
        return "turn phases: " + parts.joined(separator: " · ")
    }

    /// Whether a stream chunk counts as the model's first token. The synthetic `<think>` opener the MLX
    /// paths surface before any prefill (`MLXBrainProvider.generateStreaming`, `MLXToolTurnSession.sendHeld`)
    /// is not one: marking on it read `gen 0ms` on every thinking turn (review fold, 2026-10-25).
    public static func isFirstRealToken(_ piece: String) -> Bool {
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "<think>"
    }

    /// The first token's line, or nil when the turn never started: how long the person waited from the
    /// turn's start, and — once the stream was handed off — how much of that was generation (render,
    /// prefill, the think opener) rather than the pre-gen phases the `summary` line already names.
    public func firstTokenSummary(at instant: ContinuousClock.Instant) -> String? {
        guard let startedAt else { return nil }
        var line = "turn first token: \(Self.ms(startedAt.duration(to: instant)))ms"
        if let handedOffAt {
            line += " · gen \(Self.ms(handedOffAt.duration(to: instant)))ms"
        }
        return line
    }

    /// Whole ms, clamped at 0 — a credited duplicate of M1K3Voice's
    /// `Duration.wholeMilliseconds` (importing a voice module for a 3-line
    /// arithmetic helper would be a worse trade than the duplication).
    private static func ms(_ duration: Duration) -> Int {
        let parts = duration.components
        let value = parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000
        return value > 0 ? Int(value) : 0
    }
}
