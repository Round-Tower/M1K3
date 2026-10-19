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
//  Review: Kev + claude-opus-5-5, 2026-10-18 — four metacognition arms. Three steer the ANSWER, so they work
//  on Auto's straight turns: reread (re-read the question), trap (name the tempting wrong answer, check it),
//  working (one or two lines of shown working, checked once). budget steers a think phase: judge the
//  difficulty first, stop once the answer has been checked. terse (10-10) shortened nothing. Confidence 0.6:
//  first drafts again; the run decides.
//  Review: Kev + claude-opus-5-5, 2026-10-18 — `thought(_:)`: the block's text, so a score can keep the thinking
//  itself (Kev: eval the thinking process, not only the answer; NoWait's check is a count inside it). Confidence 0.85.
//  Review: Kev + claude-opus-5-5, 2026-10-19 — `blocks(_:)`: every block, in order. An agent turn thinks once per
//  send (each opens its own block), and `measure` reads only the first, so a tool turn's later thinking was
//  invisible to the eval. `measure` and `thought` are unchanged. Confidence 0.85.
//  Review: same day (pre-push review fold) — `blocks` starts a new block at a second open inside an unclosed one (a
//  send that hit its cap never closes), and `measure`'s doc points at it.

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
    /// the tag on (unclosed = true). Only the first block is measured here (`blocks` reads
    /// them all: an agent turn opens one per send); a second `<think>` counts as answer.
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

    /// Every block's text, in order: each to its close, and an unclosed last one to the end. An agent turn thinks
    /// once per send, and `measure` reads only the first block, so a tool turn's later thinking shows only here.
    public static func blocks(_ raw: String) -> [String] {
        var out: [String] = []
        var rest = raw[...]
        while let open = rest.range(of: openTag) {
            let afterOpen = rest[open.upperBound...]
            let close = afterOpen.range(of: closeTag)
            // A send that hit its token cap never closes; the next send opens its own block, so a second open
            // before any close ends the first block there.
            if let reopen = afterOpen.range(of: openTag), reopen.lowerBound < (close?.lowerBound ?? afterOpen.endIndex) {
                out.append(String(afterOpen[..<reopen.lowerBound]))
                rest = afterOpen[reopen.lowerBound...]
                continue
            }
            guard let close else {
                out.append(String(afterOpen))
                break
            }
            out.append(String(afterOpen[..<close.lowerBound]))
            rest = afterOpen[close.upperBound...]
        }
        return out
    }

    /// The text `measure` counts: the first block, to its close or (unclosed) to the end. nil with no block.
    public static func thought(_ raw: String) -> String? {
        guard let open = raw.range(of: openTag) else { return nil }
        let afterOpen = raw[open.upperBound...]
        guard let close = afterOpen.range(of: closeTag) else { return String(afterOpen) }
        return String(afterOpen[..<close.lowerBound])
    }
}

/// Times the think phase off a live stream: feed the FOLDED transcript so far
/// (`StreamFold` output — correct for both delta and cumulative-snapshot
/// providers) with the clock's now; `thinkMS` is the span from the first
/// token to the first non-blank answer token (nil until an answer token
/// lands, or when there was no block).
public struct ThinkPhaseClock: Sendable {
    private var firstToken: Duration?
    private var answerStart: Duration?
    private var sawOpen = false
    private var sawClose = false
    private var text = ""

    public init() {}

    public mutating func feed(transcript: String, at now: Duration) {
        guard answerStart == nil else { return }
        if firstToken == nil { firstToken = now }
        text = transcript
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
    /// Re-read the question before answering (the "re-reading" prompt).
    case reread
    /// Name the tempting quick answer and check it before trusting it.
    case trap
    /// One or two lines of shown working, checked once against the question.
    case working
    /// Judge the difficulty first; reason only as far as the answer needs, then stop.
    case budget

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
        case .reread:
            return "Before you answer, read the question again slowly and make sure you answer exactly what it "
                + "asks. Then answer normally."
        case .trap:
            return "Questions with numbers or logic often have a quick, tempting answer that is wrong. Notice the "
                + "tempting answer, check it against the question, and keep it only if it holds. Then answer normally."
        case .working:
            return "For a question with numbers or several steps, write your working in one or two short lines "
                + "and check the result against the question once. Then answer normally."
        case .budget:
            return "When you reason before answering, first judge how hard the question is. If it is easy, one "
                + "line of reasoning is enough. If it is hard, work step by step, and stop as soon as you have "
                + "checked the answer once. Then answer normally."
        }
    }
}
