//
//  AnswerBlockSpeech.swift
//  M1K3AnswerBlocks
//
//  How a typed block reads aloud (#717). Steps become "Step 1: … Step 2: …",
//  choices become "<prompt> Options: a, b, or c." — and JSON is never voiced.
//  SpeechTextPolish (M1K3Voice) runs `replacingTypedFences` as its FIRST step:
//  its later passes keep fenced code verbatim (the karaoke contract), so without
//  this a typed block would be read out brace by brace, on both the
//  whole-answer and the per-sentence lane (SentenceStreamFolder hands a closed
//  fence over as one chunk).
//
//  A fence that didn't parse, or never closed, speaks as "I've put that on
//  screen." (the issue's chart precedent): the screen shows it as a code card,
//  and reading raw JSON aloud is the one thing this lane must never do. Not "":
//  every shell's speak() reads the RAW text when polish comes back empty, and
//  the sentence folders hand a fence over as a chunk of its own, so silence
//  would have voiced the JSON in voice mode.
//
//  The wording is English on purpose: every rule in SpeechTextPolish is, and so
//  are the voices it feeds.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85 (pure; the wording
//  is a taste call, pinned in AnswerBlockSpeechTests). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-27 (self-review fold) — a malformed or unclosed fence says it is
//  on screen instead of vanishing: "" tripped the shells' raw fallback in voice mode. Confidence 0.85.
//  Review: Kev + claude-opus-5.5, 2026-10-27 (code-quality review fold) — the same rule for a PARSED block
//  whose words clean to nothing (a prompt of one backtick, an option of "?"): it spoke "". And `clean`
//  strips only a fence-length tilde run, so "~5 minutes" keeps its tilde. Confidence 0.85.
//

import Foundation

public enum AnswerBlockSpeech {
    /// What a typed fence that didn't parse, or never closed, says aloud.
    public static let onScreen = "I've put that on screen."

    /// The block as sentences, on one line. Items lose their backticks and line
    /// breaks, so the sentences can never open or close a fence downstream.
    public static func spoken(_ block: AnswerBlock) -> String {
        switch block {
        case let .steps(steps):
            return steps.enumerated()
                .map { "Step \($0.offset + 1): \(sentence($0.element))" }
                .joined(separator: " ")
        case let .choices(prompt, options):
            let items = options.map(listItem).filter { !$0.isEmpty }
            guard !items.isEmpty else { return sentence(prompt) }
            return "\(sentence(prompt)) Options: \(joinedWithOr(items))."
        }
    }

    /// The text with every typed fence replaced in place: a parsed one by its
    /// sentences, a malformed or still-open one by `onScreen`. Everything else,
    /// ordinary fences included, is untouched.
    public static func replacingTypedFences(in text: String) -> String {
        let regions = AnswerBlockSegmenter.typedRegions(in: text)
        guard !regions.isEmpty else { return text }
        var result = ""
        var cursor = text.startIndex
        for region in regions {
            result += text[cursor ..< region.range.lowerBound]
            result += replacement(for: region)
            cursor = region.range.upperBound
        }
        result += text[cursor...]
        return result
    }

    /// What one typed fence speaks as: never empty, because a lone fence chunk
    /// that polished to "" would send the shells' speak() to the raw JSON.
    static func replacement(for region: AnswerBlockSegmenter.TypedRegion) -> String {
        let words = region.block.map(spoken) ?? ""
        return words.isEmpty ? onScreen : words
    }

    // MARK: - Wording

    private static let terminators: Set<Character> = [".", "!", "?", "…"]
    private static let softEnds: Set<Character> = [",", ";", ":"]
    private static let closers: Set<Character> = ["\"", "'", ")", "]", "\u{201D}", "\u{2019}"]

    /// One line, no backticks, no leading fence marker, single-spaced.
    private static func clean(_ text: String) -> String {
        let flat = text
            .replacingOccurrences(of: "`", with: "")
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        // A leading ~~~ would read as a tilde fence opener to the passes after
        // (only a choices prompt starts a line). Fewer tildes open nothing and
        // can carry meaning ("~5 minutes", "~/Library"), so they stay.
        guard flat.hasPrefix("~~~") else { return flat }
        return String(flat.drop { $0 == "~" || $0 == " " })
    }

    /// The item ending in exactly one terminator: an existing one (even inside a
    /// closing quote) is kept, a trailing comma/colon becomes a full stop.
    private static func sentence(_ text: String) -> String {
        var item = clean(text)
        guard let last = item.last else { return "" }
        let beforeClosers = item.reversed().first { !closers.contains($0) }
        if let beforeClosers, terminators.contains(beforeClosers) { return item }
        if softEnds.contains(last) { item.removeLast() }
        return item + "."
    }

    /// An option inside a spoken list: its own end punctuation goes.
    private static func listItem(_ text: String) -> String {
        var item = clean(text)
        while let last = item.last, terminators.contains(last) || softEnds.contains(last) {
            item.removeLast()
        }
        return item
    }

    private static func joinedWithOr(_ items: [String]) -> String {
        switch items.count {
        case 1: items[0]
        case 2: "\(items[0]) or \(items[1])"
        default: items.dropLast().joined(separator: ", ") + ", or " + items[items.count - 1]
        }
    }
}
