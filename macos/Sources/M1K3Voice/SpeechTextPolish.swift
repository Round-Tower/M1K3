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
//    bullet markers, thematic breaks, GFM table rows) flattens to its spoken
//    content — the chat pipeline stopped flattening when bubbles learned to
//    RENDER markdown (2026-07-22 pass), so the speech lane owns its own
//    flatten. A table's separator row is silent and each row speaks its cells
//    as one sentence ("Tea, less."). Fenced code blocks pass through verbatim:
//    mangling `*ptr` or a shell `# comment` would corrupt the karaoke caption
//    (displayed text == spoken text).
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
//  Review: Kev + claude-opus-5-5, 2026-09-24 — the name's spoken form now comes from
//  `SpokenName.everyday`, beside the introduction's spelled form, so the two can't
//  drift. No behaviour change. Confidence now 0.9.
//  Review: Kev + claude-opus-4-6, 2026-10-12 — singular "Source:" trailing block (was only
//  "Sources:"); inline parenthetical source attributions "(Source: gov.ie)" stripped from speech.
//  AFM on iPhone was speaking full URLs from web search results. Confidence 0.9.
//  Review: Kev + claude-opus-5.5, 2026-10-15 (pre-push review fold) — the inline strip needs a colon after its key,
//  or nothing but a site: with the colon optional, "(from the Latin salarium)" and "(via Douglas)" went silent on
//  both platforms while the screen kept them. Confidence 0.9 (negative cases pinned).
//  Review: Kev + claude-opus-5.5, 2026-10-15 (pre-push review fold) — the Sources-block scan is linear: each list line
//  must run to its own end, so a long bullet or digit run that isn't the tail no longer backtracks exponentially.
//  Confidence 0.9 (a 400-character run pinned; the old form never finished it).
//  Review: Kev + claude-opus-5.5, 2026-10-15 (pre-push review fold) — `spokenSentence`: auto-speak's per-sentence
//  lane skips a sentence that polishes to nothing instead of reading it raw (a streamed Source trailer's URLs).
//  Confidence 0.9.
//  Review: Kev + claude-fable-5.1, 2026-10-26 — #716: the persona answers a comparison with a table and the speech
//  lane spoke it pipes and dashes and all; "- " bullets were read as a dash while "* " vanished. `flattenTables`
//  (a separator row goes with its line break; a row that opens with a pipe speaks its cells as "a, b.") runs
//  first inside the fence-aware flatten, and the bullet rule takes `-` and `+`. The Sources-block strip moves ahead
//  of the flatten (it keys on those markers; the existing tests caught it) and takes a bold label itself. A pipe
//  mid-prose or in a fence is untouched; a row with no edge pipe at all is the known gap (rare from the brains).
//  Confidence 0.85 (every case pinned; the ", " cell separator is a taste call).
//  Review: same day (pre-push review fold) — three things the move ahead of the flatten had cost, and one the
//  wider bullet class exposed. The Web-sources strip now runs first (the app appends that block AFTER a model's
//  Sources list, and the Sources scan is anchored to the tail); the Sources label takes every form the screen-side
//  cut (`SpokenAnswerEnd.sourcesHeader`) takes — bold either side of the colon, italic, underscores, a heading —
//  since the flatten no longer unwraps it first; and the inline "(Source: …)" strip is back AFTER the flatten, where
//  a link or emphasis inside the parens has been unwrapped. The bullet rule matches horizontal whitespace only: its
//  `\s` reached across a blank line and ate the paragraph break before every list. A line that CLOSES with a pipe is
//  a row too: auto-speak's sentence fold cuts a row at a full stop inside a cell, and the tail kept its pipe. Each
//  pinned. Confidence 0.85.
//  Review: Kev + claude-opus-5.5, 2026-10-27 — typed answer blocks (#717): the FIRST pass swaps every
//  `m1k3-steps` / `m1k3-choices` fence for its sentences (AnswerBlockSpeech), and one that didn't parse
//  or never closed for "I've put that on screen." (never "": the shells' raw fallback would read the
//  JSON). The later passes keep fences verbatim, so without it a block was read out as JSON on both
//  lanes. M1K3Voice now imports the M1K3AnswerBlocks leaf (a taste call for Kev, see Package.swift).
//  Confidence 0.85.
//

import Foundation
import M1K3AnswerBlocks

public enum SpeechTextPolish {
    /// One pass is a fixed point: every rule only removes or normalizes,
    /// never produces new strippable material. Typed answer blocks go first:
    /// their sentences are one line with no backticks, so they can't open a
    /// fence, and the passes after them flatten their markdown like any prose.
    public static func polish(_ text: String) -> String {
        var result = text
        result = AnswerBlockSpeech.replacingTypedFences(in: result)
        result = stripFollowUpTrailer(result)
        // Both trailing source blocks go BEFORE the flatten (#716): the model's
        // "Sources:" block is recognised by the "- " markers the flatten now
        // removes, and the app appends its "Web sources:" block after that one,
        // so the web block goes first to leave the model's block as the tail
        // its scan is anchored to.
        result = stripWebSourcesBlock(result)
        result = stripSourcesBlock(result)
        result = flattenMarkdownOutsideFences(result)
        // After the flatten, as before #716: "(Source: [met.ie](url))" and
        // "(*Source: gov.ie*)" are "(Source: met.ie)" by now.
        result = stripInlineSourceParens(result)
        result = stripCitations(result)
        result = collapseURLs(result)
        result = stripEmojiOutsideFences(result)
        result = speakOwnName(result)
        result = normalizeCurlyPunctuation(result)
        result = tidyWhitespace(result)
        return result
    }

    /// One streamed sentence of a longer answer (chat auto-speak), polished, or nil when nothing speakable is left:
    /// a Sources trailer streams in as a sentence of its own and polishes to "". Whole-answer speech keeps its raw
    /// fallback, because an empty utterance strands the voice loop's wait for the end; a skipped sentence strands
    /// nothing, and the raw fallback would read the trailer's URLs aloud.
    public static func spokenSentence(_ text: String) -> String? {
        let polished = polish(text)
        return polished.isEmpty ? nil : polished
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
            result += isWholeName ? SpokenName.everyday : String(text[found])
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
    /// (M1K3Chat) rather than imported — M1K3Voice depends on leaves only
    /// (the VoiceTier precedent: a Voice→Chat edge to dedupe one
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
        // Tables first (#716): the separator row and the pipes are visual, so a
        // row becomes a sentence BEFORE the emphasis passes see its cells.
        var output = flattenTables(text)
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
        // Line-leading "* ", "- " and "+ " bullet markers vanish — speech wants
        // the item, not a spoken glyph. The marker needs its space: "-5 degrees"
        // and "well-known" are not bullets. Horizontal whitespace only: a `\s`
        // here reached across a blank line and ate the paragraph break before
        // every list (and a lone "-" line swallowed the line after it).
        output = output.replacing(/^[ \t]{0,3}[*+-][ \t]+/.anchorsMatchLineEndings()) { _ in "" }
        // Heading markers vanish, the heading text stays.
        output = output.replacing(/^#{1,6}\s+/.anchorsMatchLineEndings()) { _ in "" }
        return output
    }

    /// GFM tables are visual: the separator row says nothing and a row's pipes
    /// are unspeakable. A separator row (`|---|:--:|`, `--- | ---`) vanishes
    /// with its line break, so the header row and the first body row read as
    /// neighbours; a row that opens with a pipe speaks its cells as one sentence
    /// ("Tea, less."); so does a line that CLOSES with one, because auto-speak's
    /// sentence fold cuts a row at a full stop inside a cell and the tail keeps
    /// only its closing pipe. A pipe mid-prose ("A | B") is left alone, as is a
    /// row with no edge pipe at all (valid GFM, rare from the brains — the known
    /// gap, pinned). Walks lines by `\.isNewline` like `fencedCodeRanges`, so
    /// CRLF text keeps its own line breaks.
    private static func flattenTables(_ text: String) -> String {
        var result = ""
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let newline = text[lineStart...].firstIndex(where: \.isNewline)
            let contentEnd = newline ?? text.endIndex
            let nextLine = newline.map { text.index(after: $0) } ?? text.endIndex
            let trimmed = text[lineStart ..< contentEnd].trimmingCharacters(in: .whitespaces)
            if isTableSeparator(trimmed) {
                // Dropped, line break and all.
            } else if trimmed.hasPrefix("|") || trimmed.hasSuffix("|") {
                result += spokenRow(trimmed)
                result += text[contentEnd ..< nextLine]
            } else {
                result += text[lineStart ..< nextLine]
            }
            lineStart = nextLine
        }
        return result
    }

    /// Pipes, colons, dashes and blanks only, with at least one pipe and one dash:
    /// `|---|`, `| :-- | --: |`, `--- | ---`. A bare `---` is a thematic break,
    /// handled by its own rule.
    private static func isTableSeparator(_ line: String) -> Bool {
        line.contains("|") && line.contains("-") && line.allSatisfy { "|:- \t".contains($0) }
    }

    /// `| Tea | less |` → "Tea, less." — empty edge cells dropped; a cell that
    /// already ends a sentence keeps its own full stop.
    private static func spokenRow(_ line: String) -> String {
        let cells = line.split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !cells.isEmpty else { return "" }
        let sentence = cells.joined(separator: ", ")
        let ended = sentence.last.map { ".!?".contains($0) } ?? false
        return ended ? sentence : sentence + "."
    }

    // MARK: - Rules

    /// Anchored to the end of the string: a "Web sources:" line followed only
    /// by bullet lines. Mid-prose mentions of "web sources" are untouched.
    private static func stripWebSourcesBlock(_ text: String) -> String {
        text.replacing(/(?:^|\n+)Web sources:\n(?:•[^\n]*\n?)*$/, with: "")
    }

    /// A model-written "Sources:" or "Source:" tail — a label on its own line
    /// followed by bullet / dash / bracket lines, or inline citation tokens —
    /// is chip UI, not speech (narration read one verbatim, 2026-09-12).
    /// Anchored to the end; "Two sources: the river…" mid-prose survives
    /// (line start + colon + only list/citation lines to the end).
    ///
    /// Each list line runs to its own end (`\n` or the end of the text): with
    /// an optional `\n`, every bullet or digit could open a new iteration, and
    /// a long run that wasn't the tail backtracked exponentially (the 2026-10-15
    /// review measured 3.5 s at 16 characters, on the main actor).
    ///
    /// Runs BEFORE the markdown flatten since #716 (the flatten strips the "- "
    /// markers this scan keys on), so the label takes its own markup here, in
    /// every form the screen-side cut (`SpokenAnswerEnd.sourcesHeader`) takes:
    /// `**Sources:**`, `**Sources**:`, `*Sources:*`, `__Sources__:`, `## Sources:`.
    /// Fixed-size groups, so the scan stays linear (`sourcesScanIsLinear`).
    private static func stripSourcesBlock(_ text: String) -> String {
        text.replacing(
            /(?i)(?:^|\n+)[ \t]*(?:#{1,6}[ \t]+)?(?:\*{1,2}|_{1,2})?Sources?(?:\*{1,2}|_{1,2})?:(?:\*{1,2}|_{1,2})?[ \t]*(?:\[[^\n]*)?\n?(?:[ \t]*[•\-*\[\d][^\n]*(?:\n|$))*$/,
            with: ""
        )
    }

    /// Parenthetical source attributions: "(Source: gov.ie)" or
    /// "(via gov.ie)" read as noise in speech. Keyed by Source/Via/From inside
    /// parens AND either a colon after the key or nothing but a site after it:
    /// "(from the Latin salarium)", "(via Douglas)" and "(source code is on
    /// GitHub)" are prose and still speak, as does "(an open source project)".
    private static func stripInlineSourceParens(_ text: String) -> String {
        text.replacing(
            /(?i)\s*\((?:Source|Via|From)(?::\s*[^)]+|\s+(?:https?:\/\/)?[\w-]+(?:\.[\w-]+)+(?:\/[^\s)]*)?)\)/,
            with: ""
        )
    }

    /// The follow-ups trailer in ANY spelling ("FOLLOWUPS:", "Follow-ups:",
    /// "**Follow-ups:**") and everything after it: the chat lane strips it for
    /// the bubble; the speech lane must never voice it. Mirrors
    /// `FollowUpSplit.trailerStart` (M1K3Inference — not importable here:
    /// M1K3Voice depends on leaves only): exact sentinel anywhere, variants
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
