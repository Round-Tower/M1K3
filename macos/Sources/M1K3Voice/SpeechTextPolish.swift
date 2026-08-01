//
//  SpeechTextPolish.swift
//  M1K3Voice
//
//  Sanitizes assistant text for SPEECH ONLY — the chat transcript keeps the
//  full text. The polished string is what `speak()` hands the providers, so
//  the karaoke view displays it too: the SpokenWordTimeline contract
//  (displayed text == spoken text) holds automatically.
//
//  What gets removed, and why:
//  • Markdown markup (**bold**, *italic*, `code`, # headings, [label](url),
//    bullet markers, thematic breaks) flattens to its spoken content — the
//    chat pipeline stopped flattening when bubbles learned to RENDER markdown
//    (2026-07-22 pass), so the speech lane owns its own flatten. Fenced code
//    blocks pass through verbatim: mangling `*ptr` or a shell `# comment`
//    would corrupt the karaoke caption (displayed text == spoken text).
//  • The trailing "Web sources:" bullet block — URLs read aloud are noise.
//  • Citation tokens `[Title §heading]` / `(Title §heading)` — visual
//    affordances, not speech. Plain brackets without a § survive.
//  • Inline URLs collapse to their bare host ("weather.com") — dropping them
//    entirely orphans sentences like "according to ."
//  • Curly quotes normalize to ASCII so Kokoro's dictionary hits
//    contractions ("don't" is a dict key; "don’t" is not).
//
//  Signed: Kev + claude-fable-5, 2026-06-11, Confidence 0.9 (pure string
//  transform, every rule test-pinned; URL-host readability is a taste call).
//  Prior: Unknown.
//  Review: Kev + claude-fable-5, 2026-08-01 — markdown flattening moved here
//  from MessageTextPolish (which now preserves markup for the bubble
//  renderer); rules ported from its retired polishProse, speech-tuned: a
//  link speaks its LABEL only, bullet markers vanish rather than becoming
//  "•". Runs first so the link pass sees intact `[label](url)` before
//  collapseURLs would mangle the parenthesised URL.
//

import Foundation

public enum SpeechTextPolish {
    /// One pass is a fixed point: every rule only removes or normalizes,
    /// never produces new strippable material.
    public static func polish(_ text: String) -> String {
        var result = text
        result = flattenMarkdownOutsideFences(result)
        result = stripWebSourcesBlock(result)
        result = stripCitations(result)
        result = collapseURLs(result)
        result = normalizeCurlyPunctuation(result)
        result = tidyWhitespace(result)
        return result
    }

    // MARK: - Markdown flattening

    /// Flatten markdown markup to its spoken content, leaving fenced code
    /// blocks byte-for-byte (a ``` line toggles fence state). Line-based, so
    /// an unterminated fence simply runs verbatim to the end — the same
    /// fail-safe MessageTextPolish's harness pinned.
    private static func flattenMarkdownOutsideFences(_ text: String) -> String {
        var output: [String] = []
        var prose: [String] = []
        var inFence = false

        func flushProse() {
            guard !prose.isEmpty else { return }
            output.append(flattenMarkdown(prose.joined(separator: "\n")))
            prose.removeAll()
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inFence {
                    output.append(String(line))
                    inFence = false
                } else {
                    flushProse()
                    output.append(String(line))
                    inFence = true
                }
            } else if inFence {
                output.append(String(line))
            } else {
                prose.append(String(line))
            }
        }
        flushProse()
        return output.joined(separator: "\n")
    }

    /// The rules, ported from MessageTextPolish's retired flattening pass and
    /// speech-tuned: links speak their label only; bullet markers vanish.
    private static func flattenMarkdown(_ text: String) -> String {
        var output = text
        // Thematic breaks (*** / --- / ___ alone on a line) are document
        // structure, not speech — drop the line before the emphasis passes run
        // (a bare *** would otherwise be mis-read as an unterminated italic).
        output = output.replacing(/^[ \t]*[-*_]{3,}[ \t]*$/.anchorsMatchLineEndings()) { _ in "" }
        // [label](url) → label. The URL is a visual affordance; collapseURLs
        // still handles any bare URL left in prose.
        output = output.replacing(/\[([^\]]+)\]\(([^)\s]+)\)/) { String($0.1) }
        // **bold** → bold. Runs first so ***bold-italic*** lands as
        // *bold-italic*, which the italic pass below then finishes.
        output = output.replacing(/\*\*([^*]+)\*\*/) { String($0.1) }
        // *italic* → italic. Only a properly-paired *word* where the content
        // touches both asterisks — arithmetic ("2 * 3") and the "* " bullet
        // marker survive. Group 1 preserves the leading boundary; the trailing
        // boundary is a zero-width lookahead so it isn't consumed.
        output = output.replacing(
            /(^|[\s(\[])\*(\S(?:[^*\n]*\S)?|\S)\*(?=$|[\s).,;:!?\]])/.anchorsMatchLineEndings()
        ) { "\($0.1)\($0.2)" }
        // ```code``` (same-line span, NOT a fence — those never reach prose)
        // → code. Before the single-backtick pass, whose innermost-pair match
        // would leave stray ``doubles`` behind.
        output = output.replacing(/```([^`\n]+)```/) { String($0.1) }
        // `code` → code
        output = output.replacing(/`([^`\n]+)`/) { String($0.1) }
        // Line-leading "* " bullet markers vanish — speech wants the item, not
        // a spoken glyph.
        output = output.replacing(/^\s{0,3}\*\s+/.anchorsMatchLineEndings()) { _ in "" }
        // Heading markers vanish, the heading text stays.
        output = output.replacing(/^#{1,6}\s+/.anchorsMatchLineEndings()) { _ in "" }
        return output
    }

    // MARK: - Rules

    /// Anchored to the end of the string: a "Web sources:" line followed only
    /// by bullet lines. Mid-prose mentions of "web sources" are untouched.
    private static func stripWebSourcesBlock(_ text: String) -> String {
        text.replacing(/(?:^|\n+)Web sources:\n(?:•[^\n]*\n?)*$/, with: "")
    }

    /// Citation tokens carry a `§` between the source title and heading —
    /// that marker is the discriminator (plain `[1]` or `(see above)` stay).
    private static func stripCitations(_ text: String) -> String {
        var result = text.replacing(/\[[^\]\n]*§[^\]\n]*\]/, with: "")
        result = result.replacing(/\([^)\n]*§[^)\n]*\)/, with: "")
        return result
    }

    /// `https://www.weather.com/today?x=1` → `weather.com`.
    private static func collapseURLs(_ text: String) -> String {
        text.replacing(/https?:\/\/(?:www\.)?([^\/\s?#]+)[^\s]*/) { match in
            // A URL swallows trailing sentence punctuation into its path —
            // peel it back off so "at https://met.ie/x." reads "at met.ie."
            let tail = match.output.0.last.map(String.init) ?? ""
            let punctuation = [".", ",", "!", "?", ";", ":"].contains(tail) ? tail : ""
            return String(match.output.1) + punctuation
        }
    }

    private static func normalizeCurlyPunctuation(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
    }

    private static func tidyWhitespace(_ text: String) -> String {
        var result = text.replacing(/[ \t]+/, with: " ")
        // Plain string ops, not a capture-group regex — the repo formatter
        // strips "redundant" parens inside regex literals and breaks .output.
        for punctuation in [".", ",", "!", "?", ";", ":"] {
            result = result.replacingOccurrences(of: " " + punctuation, with: punctuation)
        }
        result = result.replacing(/[ \t]+\n/, with: "\n")
        result = result.replacing(/\n[ \t]+/, with: "\n")
        result = result.replacing(/\n{3,}/, with: "\n\n")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
