//
//  ReadSanitizer.swift
//  M1K3Inference
//
//  The read route's first stage: text someone hands M1K3 (a paste, a shared
//  page, a file) made safe and plain before any brain sees it. Three jobs:
//
//  1. HTML becomes its readable text (`HTMLTextExtractor`, the page reader's
//     hardened strip): comments, scripts, styles and page chrome go, which is
//     also where hidden instructions like to sit.
//  2. Characters nobody can see go: Unicode format characters (zero-width,
//     bidi controls, BOM, the U+E0000 tag block, all general category Cf) and
//     control characters other than line breaks and tabs. An instruction spelt
//     in them reads as nothing on screen and as words to a tokenizer.
//  3. Chat-template tokens are neutralised. A tokenizer turns `<|im_start|>`
//     in plain text into the REAL special token, so a pasted
//     `<|im_start|>system` opens a system turn on Qwen; the same goes for each
//     brain's own markers. They are removed, not escaped.
//
//  It also tidies whitespace (trailing spaces, runs of blank lines), which is
//  token budget on a 4,096-token Mini.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-14, Confidence 0.8, Prior: none (new file)
//  Context: Kev, 2026-11-14: "Context ingestion & compression / sanitization, and analysis
//  without system prompt - similar to vision"; instructions only (his call).
//  Review: Kev + claude-opus-5.5, 2026-11-14 (pre-push review fold) — the token strip runs to a fixed point
//  (nested tokens reassembled after one pass), covers Gemma 4's `<|"|>`, `<pad>`, `<unusedN>` and the
//  start/end markers, and no longer eats F#'s `<|`; literals match case exactly. Joiners between non-ASCII
//  scalars stay (emoji families, Persian ZWNJ); form feeds become line breaks.
//  Open: hidden HTML that is not a comment (display:none, the hidden attribute) is kept as
//  text; the fence and the eval's injection set decide whether that needs its own strip.
//

import Foundation

public enum ReadSanitizer {
    public static func clean(_ text: String) -> String {
        var work = looksLikeHTML(text) ? HTMLTextExtractor.text(from: text) : text
        work = droppingInvisibles(work)
        work = neutralisingTemplateTokens(work)
        return tidyingWhitespace(work)
    }

    /// Markup worth stripping: a document opener, or several common tags. Prose that
    /// mentions one tag or uses `<` as maths stays as it is.
    static func looksLikeHTML(_ text: String) -> Bool {
        let head = text.prefix(4096).lowercased()
        if ["<!doctype html", "<html", "<body"].contains(where: head.contains) { return true }
        let tags = ["<p>", "<p ", "<div", "<span", "<br", "<li", "<a href", "<table", "<h1", "<h2", "<!--"]
        return tags.reduce(0) { $0 + head.components(separatedBy: $1).count - 1 } >= 3
    }

    /// Format characters go, except a joiner (ZWJ, ZWNJ) between two non-ASCII scalars: that one
    /// is spelling (an emoji family, a Persian or Indic word), not smuggling, which needs ASCII to
    /// hide between. Form and line feeds of other kinds become line breaks; other controls go.
    static func droppingInvisibles(_ text: String) -> String {
        let source = Array(text.unicodeScalars)
        var scalars = String.UnicodeScalarView()
        for (index, scalar) in source.enumerated() {
            switch scalar.properties.generalCategory {
            case .format:
                let joiner = scalar == "\u{200C}" || scalar == "\u{200D}"
                let before = index > 0 ? source[index - 1] : nil
                let after = index + 1 < source.count ? source[index + 1] : nil
                if joiner, let before, let after, !before.isASCII, !after.isASCII,
                   before.properties.generalCategory != .format, after.properties.generalCategory != .format
                {
                    scalars.append(scalar)
                }
            case .control where scalar == "\u{000B}" || scalar == "\u{000C}" || scalar == "\u{0085}":
                scalars.append("\n")
            case .control where scalar != "\n" && scalar != "\t" && scalar != "\r":
                continue
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// Every brain's turn and tool markers that the shapes below miss. Removed whole, case exact
    /// (a tokenizer matches them exactly, and prose may say "<S>").
    static let templateTokens = [
        "[INST]", "[/INST]", "<<SYS>>", "<</SYS>>",
        "<think>", "</think>", "<tool_call>", "</tool_call>", "<tool_response>", "</tool_response>",
        "<s>", "</s>", "<bos>", "<eos>", "<pad>", "<mask>", "<unk>",
    ]

    /// The special-token SHAPES: `<|…|>` with no space inside (Qwen's turns, Gemma 4's `<|"|>`),
    /// Gemma 4's one-sided `<|turn>` / `<turn|>`, Gemma's `<start_of_…>` / `<end_of_…>`, its
    /// `<unusedN>`, and the image placeholders. No space is allowed inside, so F#'s `a <| f >> g` stays.
    nonisolated(unsafe) static let tokenShapes = /<\|[^\s<>|]{0,40}\|>|<\|[A-Za-z_]{1,24}>|<[A-Za-z_]{1,24}\|>|<(?:start|end)_[a-z_]{1,32}>|<unused\d{1,4}>|<[a-z]{1,16}_soft_token>/

    static func neutralisingTemplateTokens(_ text: String) -> String {
        // Until nothing changes: removing an inner token must not leave an outer one assembled
        // (`<|im<|x|>_start|>`). Each pass only shortens the text, so this ends; eight is a backstop.
        var work = text
        for _ in 0 ..< 8 {
            var next = work.replacing(tokenShapes, with: "")
            for token in templateTokens {
                next = next.replacingOccurrences(of: token, with: "")
            }
            if next == work { break }
            work = next
        }
        return work
    }

    static func tidyingWhitespace(_ text: String) -> String {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { line in
                var trimmed = Substring(line)
                while let last = trimmed.last, last == " " || last == "\t" {
                    trimmed = trimmed.dropLast()
                }
                return String(trimmed)
            }
        var kept: [String] = []
        for line in lines where !(line.isEmpty && (kept.last?.isEmpty ?? true)) {
            kept.append(line)
        }
        while kept.last?.isEmpty == true {
            kept.removeLast()
        }
        return kept.joined(separator: "\n")
    }
}
