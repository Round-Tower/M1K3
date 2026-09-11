//
//  NarrationLine.swift
//  M1K3Voice
//
//  The one line the notch HUD shows for an utterance: the sentence that
//  contains the word being spoken, or the first sentence before any word has
//  been reported. Whitespace runs — newlines included — collapse to a single
//  space, so a multi-paragraph `speak` from a visiting agent can never lay
//  out as stacked full-width lines the panel clips on both sides (Kev's
//  screenshot, 2026-09-11). The chat's own auto-speak already speaks one
//  sentence per utterance; the MCP path speaks the whole text at once, which
//  is where the multi-line utterance came from.
//
//  Sentence boundaries: a terminal mark (. ! ? …) followed by whitespace or
//  the end, or a newline (a paragraph without punctuation still ends). Offsets
//  are UTF-16 — the word-range convention the karaoke highlight state uses.
//  Review: Kev + claude-fable-5.1, 2026-09-11 (review 2 fold) — `currentLine` also carries the
//  sentence's START offset so the HUD can key its marquee restart on position: keyed on the text,
//  "Done. Done." never restarted the scroll.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-11, Confidence 0.85 (pure, pinned in
//  NarrationLineTests; the HUD wiring is verify-by-launch). Prior: Unknown.
//

import Foundation

public enum NarrationLine {
    /// One HUD line: the sentence text and where it STARTS in the utterance
    /// (UTF-16). Two identical sentences at different positions are different
    /// lines — the view keys its marquee restart on `start`, never the text.
    public struct Line: Equatable, Sendable {
        public let text: String
        public let start: Int
    }

    /// The sentence of `text` containing `wordRange` (UTF-16 offsets), or the
    /// first sentence when `wordRange` is nil; a range past the end resolves
    /// to the last sentence. Whitespace-collapsed and trimmed; "" for empty text.
    public static func current(in text: String, wordRange: Range<Int>?) -> String {
        currentLine(in: text, wordRange: wordRange).text
    }

    /// `current` with the picked sentence's start offset (0 for empty text).
    public static func currentLine(in text: String, wordRange: Range<Int>?) -> Line {
        let sentences = sentenceRanges(in: text)
        guard let first = sentences.first else { return Line(text: "", start: 0) }
        let pick: Range<Int>
        if let word = wordRange {
            pick = sentences.first { $0.contains(word.lowerBound) }
                ?? sentences.last { $0.lowerBound <= word.lowerBound }
                ?? first
        } else {
            pick = first
        }
        return Line(text: collapse(substring(of: text, utf16: pick)), start: pick.lowerBound)
    }

    /// UTF-16 ranges of the sentences in `text`, empty ones dropped.
    static func sentenceRanges(in text: String) -> [Range<Int>] {
        let units = Array(text.utf16)
        var ranges: [Range<Int>] = []
        var start = 0
        var i = 0
        func close(_ end: Int, thenSkip skip: Int) {
            // A range starts at its first non-blank unit, so `start` is the
            // sentence's real position (the marquee keys its restart on it),
            // never the space left behind by the previous terminal.
            var lower = start
            while lower < end, isWhitespace(units[lower]) {
                lower += 1
            }
            if lower < end {
                ranges.append(lower ..< end)
            }
            start = end + skip
        }
        while i < units.count {
            let unit = units[i]
            if isNewline(unit) {
                close(i, thenSkip: 1)
            } else if isTerminal(unit) {
                // Run of terminals ("?!", "...") ends together.
                var j = i
                while j + 1 < units.count, isTerminal(units[j + 1]) {
                    j += 1
                }
                if j + 1 == units.count || isWhitespace(units[j + 1]) {
                    close(j + 1, thenSkip: 0)
                }
                i = j
            }
            i += 1
        }
        close(units.count, thenSkip: 0)
        return ranges
    }

    private static func substring(of text: String, utf16 range: Range<Int>) -> String {
        let lower = String.Index(utf16Offset: range.lowerBound, in: text)
        let upper = String.Index(utf16Offset: range.upperBound, in: text)
        return String(text[lower ..< upper])
    }

    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func isBlank(_ slice: ArraySlice<UInt16>) -> Bool {
        slice.allSatisfy(isWhitespace)
    }

    private static func isNewline(_ u: UInt16) -> Bool {
        u == 0x0A || u == 0x0D || u == 0x2028 || u == 0x2029
    }

    private static func isWhitespace(_ u: UInt16) -> Bool {
        isNewline(u) || u == 0x20 || u == 0x09 || u == 0xA0
    }

    private static func isTerminal(_ u: UInt16) -> Bool {
        u == 0x2E || u == 0x21 || u == 0x3F || u == 0x2026 // . ! ? …
    }
}
