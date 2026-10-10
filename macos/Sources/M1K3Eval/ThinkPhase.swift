//
//  ThinkPhase.swift
//  M1K3Eval
//
//  The think phase, measured (2026-10-10): Lil (Qwen3.5-4B) reasons at length
//  and the eval recorded only wall-clock, so "the reasoning is running wild"
//  was a feeling, not a number. `ThinkPhase.measure` reads the think block out
//  of a raw transcript (chars, whether it closed); `ThinkPhaseClock` times the
//  live stream (first token → first answer token); `ThinkSteer` is the A/B
//  clause the eval appends to the turn's rules — terse notes, emoji shorthand,
//  or a soft word cap — so the arms can be compared on the same fixtures.
//  Pure; the stage wires the stream and the env.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-10, Confidence 0.8, Prior: none (new
//  file). Open: the steer clauses are first drafts — the run decides them.

import Foundation

/// What the think block of one turn cost.
public struct ThinkPhaseMetrics: Sendable, Equatable, Codable {
    /// Characters inside `<think>…</think>` (≈ tokens × 4 for English prose).
    public let thinkChars: Int
    /// Characters of the answer outside the block.
    public let answerChars: Int
    /// The block opened but never closed — the budget was spent inside it.
    public let unclosed: Bool

    public init(thinkChars: Int, answerChars: Int, unclosed: Bool) {
        self.thinkChars = thinkChars
        self.answerChars = answerChars
        self.unclosed = unclosed
    }
}

public enum ThinkPhase {
    public static let openTag = "<think>"
    public static let closeTag = "</think>"

    /// Splits a raw transcript into its think block and its answer. A transcript
    /// with no block is all answer; a block that never closes is all think from
    /// the tag on (unclosed = true). Only the first block is measured — a second
    /// `<think>` after the answer started is malformed output and counts as answer.
    public static func measure(_ raw: String) -> ThinkPhaseMetrics {
        guard let open = raw.range(of: openTag) else {
            return ThinkPhaseMetrics(thinkChars: 0, answerChars: raw.count, unclosed: false)
        }
        let before = raw[..<open.lowerBound].count
        let afterOpen = raw[open.upperBound...]
        guard let close = afterOpen.range(of: closeTag) else {
            return ThinkPhaseMetrics(thinkChars: afterOpen.count, answerChars: before, unclosed: true)
        }
        let think = afterOpen[..<close.lowerBound].count
        let answer = before + afterOpen[close.upperBound...].count
        return ThinkPhaseMetrics(thinkChars: think, answerChars: answer, unclosed: false)
    }
}

/// Times the think phase off a live stream: feed every chunk with the clock's
/// now; `thinkMS` is the span from the first token to the first non-blank
/// answer token (nil until an answer token lands, or when there was no block).
public struct ThinkPhaseClock: Sendable {
    private var firstToken: Duration?
    private var answerStart: Duration?
    private var sawOpen = false
    private var sawClose = false
    private var text = ""

    public init() {}

    public mutating func feed(_ chunk: String, at now: Duration) {
        guard answerStart == nil else { return }
        if firstToken == nil { firstToken = now }
        text += chunk
        if !sawOpen, text.contains(ThinkPhase.openTag) { sawOpen = true }
        if sawOpen, !sawClose, text.contains(ThinkPhase.closeTag) { sawClose = true }
        let answerSoFar: Substring
        if sawOpen {
            guard sawClose, let close = text.range(of: ThinkPhase.closeTag) else { return }
            answerSoFar = text[close.upperBound...]
        } else {
            answerSoFar = text[...]
        }
        if answerSoFar.contains(where: { !$0.isWhitespace }) { answerStart = now }
    }

    /// Milliseconds from the first token to the first answer token; nil without a
    /// think block (nothing was thought) or when the answer never started.
    public var thinkMS: Int? {
        guard sawOpen, let firstToken, let answerStart else { return nil }
        let span = answerStart - firstToken
        return Int(span.components.seconds * 1000 + span.components.attoseconds / 1_000_000_000_000_000)
    }
}

/// The think-phase steer arms (`M1K3_SELFTEST_CHATEVAL_THINK_STEER`): a clause
/// appended to the turn's rules, the only difference between arms.
public enum ThinkSteer: String, Sendable, CaseIterable {
    case none
    /// Telegraphic notes: fragments and arrows, stop when the answer is clear.
    case terse
    /// Emoji shorthand with a few key words — Kev's "reasoning in emoji".
    case emoji
    /// A soft word cap on the reasoning.
    case softcap

    public init(envValue: String?) {
        let raw = envValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        self = ThinkSteer(rawValue: raw) ?? .none
    }

    /// The rules clause, or nil for the baseline.
    public var clause: String? {
        switch self {
        case .none:
            return nil
        case .terse:
            return "When you reason before answering, think in terse telegraphic notes — fragments, arrows, "
                + "no full sentences — and stop reasoning the moment the answer is clear. Then answer normally."
        case .emoji:
            return "When you reason before answering, think in compact emoji shorthand with only a few key words "
                + "per line — the reasoning is a sketch, not prose. Then answer normally, in words."
        case .softcap:
            return "When you reason before answering, keep the reasoning under 120 words. Then answer normally."
        }
    }
}
