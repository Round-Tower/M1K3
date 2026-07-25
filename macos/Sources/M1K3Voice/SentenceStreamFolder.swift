//
//  SentenceStreamFolder.swift
//  M1K3Voice
//
//  Folds a CUMULATIVE streaming text (the transcript message grows as tokens
//  land) into complete sentences, each emitted exactly once — the seam behind
//  voice mode's sentence-streamed speech: TTS starts on the first sentence
//  instead of after the whole ~25s generation (Kev's 07-25 "voice takes ages").
//
//  Emission rules (all test-pinned):
//  • A sentence ends at [.!?…]+ followed by whitespace — a TRAILING terminator
//    is held, because the next token could extend it ("3." → "3.14").
//  • A blank-line paragraph break is a boundary even without a terminator
//    (headings stream without periods).
//  • A digits-only fragment ("1.") is never emitted alone — it folds into the
//    following sentence, so list numbering isn't spoken as a lonely "one."
//  • A ``` fence is held until its closing fence — code blocks travel whole
//    (SpeechTextPolish downstream decides how they sound).
//  • From `stopMarker` on, everything is dropped — the FOLLOWUPS trailer is
//    chip UI, never speech.
//  • Cumulative input that shrinks/diverges resets the stream defensively.
//
//  Signed: Kev + claude-fable-5, 2026-07-25, Confidence 0.9, Prior: Unknown
//

import Foundation

public struct SentenceStreamFolder: Sendable {
    /// Characters that can end a sentence.
    private static let terminators: Set<Character> = [".", "!", "?", "…"]

    private let stopMarker: String?
    /// Offset into the cumulative text up to which everything was consumed.
    private var consumed: String.Index?
    /// Prefix of the cumulative text we've already seen (divergence guard).
    private var seen = ""
    /// True once the stop marker was hit — nothing further ever emits.
    private var stopped = false
    /// A held digits-only fragment awaiting its sentence body.
    private var heldPrefix = ""

    public init(stopMarker: String? = nil) {
        self.stopMarker = stopMarker
    }

    /// Feed the latest cumulative text; returns newly completed sentences.
    public mutating func ingest(_ cumulative: String) -> [String] {
        guard !stopped else { return [] }
        // Divergence guard: the stream must only grow. A shrink/replace means
        // we're looking at a different message — start over from here.
        if !cumulative.hasPrefix(seen) {
            seen = ""
            consumed = nil
            heldPrefix = ""
        }
        seen = cumulative

        var working = cumulative
        // Cut at the stop marker (even a partial trailer never emits past it).
        if let stopMarker, let range = working.range(of: stopMarker) {
            working = String(working[..<range.lowerBound])
            stopped = true
        }

        var start = consumed ?? working.startIndex
        guard start <= working.endIndex else { // divergence paranoia
            consumed = working.endIndex
            return []
        }
        var out: [String] = []
        while let boundary = nextBoundary(in: working, from: start) {
            let raw = String(working[start ..< boundary])
            start = boundary
            emit(raw, into: &out)
        }
        consumed = start

        if stopped {
            // The trailer is UI, not speech — drop any tail before it too?
            // No: everything BEFORE the marker that formed sentences already
            // emitted above; the unterminated remainder right before the
            // marker still deserves a flush.
            let tail = String(working[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
            heldPrefix = ""
            consumed = working.endIndex
            seen = cumulative
            if !tail.isEmpty, !isDigitsOnly(tail) {
                out.append(tail)
            }
        }
        return out
    }

    /// Emit the unterminated remainder (call once generation has finished).
    public mutating func flush() -> String? {
        guard !stopped else { return nil }
        let start = consumed ?? seen.startIndex
        var tail = heldPrefix + String(seen[start...])
        heldPrefix = ""
        consumed = seen.endIndex
        tail = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else { return nil }
        return tail
    }

    // MARK: - Internals

    /// Appends a candidate sentence, folding held digit-only prefixes in and
    /// holding digit-only candidates back.
    private mutating func emit(_ raw: String, into out: inout [String]) {
        let candidate = heldPrefix + raw.trimmingCharacters(in: .whitespacesAndNewlines)
        heldPrefix = ""
        guard !candidate.isEmpty else { return }
        if isDigitsOnly(candidate) {
            heldPrefix = candidate + " "
            return
        }
        out.append(candidate)
    }

    /// True when the fragment has no letters — list numbering like "1." or "2)".
    private func isDigitsOnly(_ text: String) -> Bool {
        !text.contains(where: \.isLetter)
    }

    /// The index just past the next sentence boundary at/after `from`, or nil
    /// when no COMPLETE boundary exists yet (trailing terminators are held for
    /// more tokens). Fenced code is skipped as an atomic unit.
    private func nextBoundary(in text: String, from: String.Index) -> String.Index? {
        var i = from
        while i < text.endIndex {
            // A fence is its own chunk: content before it emits first
            // (boundary AT the fence), then the block travels whole once its
            // closing fence lands, held open until then.
            if text[i...].hasPrefix("```") {
                if i > from { return i }
                let afterOpen = text.index(i, offsetBy: 3)
                guard let close = text.range(of: "```", range: afterOpen ..< text.endIndex) else {
                    return nil // fence still open — hold everything
                }
                return close.upperBound
            }
            let ch = text[i]
            if Self.terminators.contains(ch) {
                // Swallow a terminator run (?!, ..., etc).
                var j = text.index(after: i)
                while j < text.endIndex, Self.terminators.contains(text[j]) {
                    j = text.index(after: j)
                }
                guard j < text.endIndex else { return nil } // trailing — hold
                if text[j].isWhitespace { return j }
                i = j
                continue
            }
            // Paragraph break: boundary without a terminator.
            if ch == "\n" {
                var j = text.index(after: i)
                var newlines = 1
                while j < text.endIndex, text[j] == "\n" || text[j] == "\r" {
                    if text[j] == "\n" { newlines += 1 }
                    j = text.index(after: j)
                }
                if newlines >= 2 { return j }
            }
            i = text.index(after: i)
        }
        return nil
    }
}
