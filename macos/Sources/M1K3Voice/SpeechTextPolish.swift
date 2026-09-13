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
//  Review: Kev + claude-fable-5.1, 2026-09-08 — emoji stripped from the
//  speech lane (Kev heard "party popper" read aloud). Per grapheme cluster,
//  outside fences, keyed on emoji PRESENTATION so © and → still speak; bare
//  Misc Symbols / Dingbats (✔ ☺ ♠) go too (review catch on #247).
//  Confidence now 0.9 (eight pinned cases incl. ZWJ/flag/keycap; the
//  "strip rather than voice as inflection" choice is taste).
//  Review: Kev + claude-fable-5.1, 2026-09-12 — two more trailers never speak: a model-written
//  "Sources:" list and the follow-ups trailer in any spelling (narration read both verbatim —
//  launch snag list). Confidence now 0.9 (pinned incl. the mid-prose non-matches).
//

import Foundation

public enum SpeechTextPolish {
    /// One pass is a fixed point: every rule only removes or normalizes,
    /// never produces new strippable material.
    public static func polish(_ text: String) -> String {
        var result = text
        result = stripFollowUpTrailer(result)
        result = flattenMarkdownOutsideFences(result)
        result = stripWebSourcesBlock(result)
        result = stripSourcesBlock(result)
        result = stripCitations(result)
        result = collapseURLs(result)
        result = stripEmojiOutsideFences(result)
        result = speakOwnName(result)
        result = normalizeCurlyPunctuation(result)
        result = tidyWhitespace(result)
        return result
    }

    // MARK: - The name

    /// M1K3 is leetspeak for MIKE (1→I, 3→E), and no TTS engine can know that.
    /// Kokoro spells it out per character — and silently drops letters its
    /// dictionary lacks, which is why Kev heard "M1K3" arrive without its "M"
    /// (2026-08-11). AVSpeech reads it as an alphanumeric jumble. Rewriting the
    /// TEXT fixes every engine and both platforms at once, where an engine
    /// dictionary entry would fix one.
    ///
    /// Whole word only, and deliberately nothing else: this runs over every spoken
    /// answer, so a looser rule would start rewriting the user's own content —
    /// `app.m1k3`, `M1K3Voice`, a file path. `\b` won't do it (`.` and the digits
    /// make the boundaries lie), so the guard is explicit on both sides:
    /// letters/digits/`.`/`_`/`-` adjacent means it's part of something bigger.
    /// A trailing `'s` is allowed through as the possessive it is.
    private static func speakOwnName(_ text: String) -> String {
        let name = "m1k3"
        var result = ""
        var index = text.startIndex
        while let found = text.range(of: name, options: .caseInsensitive, range: index ..< text.endIndex) {
            let precedes = found.lowerBound > text.startIndex
                ? text[text.index(before: found.lowerBound)] : nil
            let follows = found.upperBound < text.endIndex ? text[found.upperBound] : nil
            // A dot AFTER the name is usually the end of a sentence, but a dot
            // BEFORE it never is (`app.m1k3`) — so the two sides can't share one
            // rule. A trailing dot only blocks when something identifier-shaped
            // follows it (`m1k3.swift`).
            let afterDot = follows == "." && found.upperBound < text.endIndex
                ? text[text.index(after: found.upperBound)...].first : nil
            let trailingIsPath = follows == "." && (afterDot?.isLetter == true || afterDot?.isNumber == true)
            result += text[index ..< found.lowerBound]
            let isWholeName = precedesBoundary(precedes)
                && !trailingIsPath
                && (follows == "." || followsBoundary(follows))
            result += isWholeName ? "Mike" : text[found]
            index = found.upperBound
        }
        result += text[index ..< text.endIndex]
        return result
    }

    /// Nil (string start) or anything that can't be part of a longer identifier.
    /// `.`/`_`/`-` all block: `app.m1k3`, `the_m1k3_app`, `run-m1k3`.
    private static func precedesBoundary(_ character: Character?) -> Bool {
        guard let character else { return true }
        if character == "." || character == "_" || character == "-" { return false }
        return !character.isLetter && !character.isNumber
    }

    /// Nil (string end) or ordinary punctuation/space. `'` passes so the
    /// possessive ("M1K3's memory") speaks as one word.
    private static func followsBoundary(_ character: Character?) -> Bool {
        guard let character else { return true }
        if character == "_" || character == "-" { return false }
        return !character.isLetter && !character.isNumber
    }

    // MARK: - Emoji

    /// Emoji are visual punctuation; spoken, every engine reads their names
    /// ("party popper") and Kokoro spells the odd one out letter by letter.
    /// Stripped per grapheme cluster so ZWJ families, skin tones, flags and
    /// keycaps go as one unit. A cluster is emoji when its lead scalar has
    /// default emoji PRESENTATION, or when it carries VS16 (`\u{FE0F}`, the
    /// "show me as emoji" selector — keycaps and `\u{2764}\u{FE0F}`), or a
    /// regional indicator. Text-presentation symbols (©, →) and bare digits
    /// have the Emoji property too but NOT presentation — they still speak.
    /// Fenced code passes through verbatim (the karaoke contract).
    private static func stripEmojiOutsideFences(_ text: String) -> String {
        var result = ""
        var cursor = text.startIndex
        for range in fencedCodeRanges(in: text) {
            result += stripEmoji(String(text[cursor ..< range.lowerBound]))
            result += String(text[range])
            cursor = range.upperBound
        }
        result += stripEmoji(String(text[cursor...]))
        return result
    }

    private static func stripEmoji(_ text: String) -> String {
        String(text.filter { !isEmojiCluster($0) })
    }

    private static func isEmojiCluster(_ character: Character) -> Bool {
        guard let lead = character.unicodeScalars.first else { return false }
        if lead.properties.isEmojiPresentation { return true }
        // Text-presentation emoji the models emit bare (✔ ☺ ♠ ☀): Emoji=Yes
        // but no default emoji face, so the presentation check misses them —
        // and engines still read them by name. The Misc Symbols + Dingbats
        // blocks are where they live; © ® ™ and digits sit outside them.
        if lead.properties.isEmoji, (0x2600 ... 0x27BF).contains(lead.value) { return true }
        if (0x1F1E6 ... 0x1F1FF).contains(lead.value) { return true } // regional indicator
        return character.unicodeScalars.contains { $0.value == 0xFE0F }
    }

    // MARK: - Markdown flattening

    /// Flatten markdown markup to its spoken content, leaving fenced code
    /// blocks byte-for-byte. An unterminated fence runs verbatim to the end —
    /// the same fail-safe MessageTextPolish's harness pinned.
    private static func flattenMarkdownOutsideFences(_ text: String) -> String {
        var result = ""
        var cursor = text.startIndex
        for range in fencedCodeRanges(in: text) {
            result += flattenMarkdown(String(text[cursor ..< range.lowerBound]))
            result += String(text[range]) // verbatim
            cursor = range.upperBound
        }
        result += flattenMarkdown(String(text[cursor...]))
        return result
    }

    /// Deliberately DUPLICATED from `MessageTextPolish.fencedCodeRanges`
    /// (M1K3Chat) rather than imported — M1K3Voice is dependency-free by
    /// design (the VoiceTier precedent: a Voice→Chat edge to dedupe one
    /// scanner is worse layering than duplication). Keep the two in
    /// lock-step; every rule here was earned by a pinned test over there:
    /// `\.isNewline` (CRLF is ONE grapheme), the closing run-length match,
    /// and CommonMark's no-backticks-in-info-string opener guard.
    private static func fencedCodeRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var openStart: String.Index?
        var openRun = 0
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let newline = text[lineStart...].firstIndex(where: \.isNewline)
            let contentEnd = newline ?? text.endIndex
            let nextLine = newline.map { text.index(after: $0) } ?? text.endIndex
            let line = text[lineStart ..< contentEnd]
            // ANY leading whitespace is tolerated (wider than CommonMark's
            // 3-space rule, on purpose): don't drop nested real code into the
            // flatten pass.
            let unindented = line.drop { $0 == " " || $0 == "\t" }
            let run = unindented.prefix { $0 == "`" }.count
            if let start = openStart {
                if run >= openRun, unindented.dropFirst(run).allSatisfy(\.isWhitespace) {
                    ranges.append(start ..< contentEnd)
                    openStart = nil
                }
            } else if run >= 3, !unindented.dropFirst(run).contains("`") {
                // A same-line ```span``` fails this guard and stays prose —
                // flattenMarkdown's span pass handles it; misreading it as an
                // unclosed opener would leave the rest of the message spoken
                // with its markup intact.
                openStart = lineStart
                openRun = run
            }
            lineStart = nextLine
        }
        if let start = openStart {
            ranges.append(start ..< text.endIndex)
        }
        return ranges
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

    /// A model-written "Sources:" tail — a label on its own line followed by
    /// bullet / dash / bracket lines, or inline citation tokens — is chip UI,
    /// not speech (narration read one verbatim, 2026-09-12). Anchored to the
    /// end; "Two sources: the river…" mid-prose survives (line start + colon
    /// + only list/citation lines to the end).
    private static func stripSourcesBlock(_ text: String) -> String {
        text.replacing(
            /(?i)(?:^|\n+)[ \t]*Sources:[ \t]*(?:\[[^\n]*)?\n?(?:[ \t]*[•\-*\[\d][^\n]*\n?)*$/,
            with: ""
        )
    }

    /// The follow-ups trailer in ANY spelling ("FOLLOWUPS:", "Follow-ups:",
    /// "**Follow-ups:**") and everything after it: the chat lane strips it for
    /// the bubble; the speech lane must never voice it. Mirrors
    /// `FollowUpSplit.trailerStart` (M1K3Inference — not importable here by
    /// the module's dependency-free rule): exact sentinel anywhere, variants
    /// at a line start only, plural, colon.
    private static func stripFollowUpTrailer(_ text: String) -> String {
        if let exact = text.range(of: "FOLLOWUPS:") {
            return String(text[..<exact.lowerBound])
        }
        if let variant = text.firstMatch(of: /(?im)^[ \t]*(?:\*\*|#{1,6}[ \t]*)?FOLLOW[ \-]?UPS(?:\*\*)?[ \t]*:/) {
            return String(text[..<variant.range.lowerBound])
        }
        return text
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
