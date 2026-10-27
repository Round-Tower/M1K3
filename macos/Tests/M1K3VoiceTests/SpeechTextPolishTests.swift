import Foundation
import M1K3Voice
import Testing

struct SpeechTextPolishTests {
    // MARK: - Web sources block

    @Test("trailing Web sources block is stripped entirely")
    func stripsWebSourcesBlock() {
        let text = "It is 15 degrees in Cork today.\n\nWeb sources:\n• https://weather.com/cork\n• https://met.ie/forecast"
        #expect(SpeechTextPolish.polish(text) == "It is 15 degrees in Cork today.")
    }

    @Test("Web sources block after a single blank line is stripped")
    func stripsWebSourcesBlockSingleNewline() {
        let text = "Sunny all week.\nWeb sources:\n• https://weather.com"
        #expect(SpeechTextPolish.polish(text) == "Sunny all week.")
    }

    @Test("the phrase Web sources mid-sentence is not treated as a block")
    func keepsWebSourcesProse() {
        let text = "I checked several web sources: none agreed."
        #expect(SpeechTextPolish.polish(text) == "I checked several web sources: none agreed.")
    }

    // MARK: - Citation tokens

    @Test("bracket citations with section marks are stripped")
    func stripsBracketCitations() {
        let text = "Revenue rose 12% [Quarterly Report §Revenue] in the third quarter."
        #expect(SpeechTextPolish.polish(text) == "Revenue rose 12% in the third quarter.")
    }

    @Test("paren citations with section marks are stripped")
    func stripsParenCitations() {
        let text = "Revenue rose (Quarterly Report §Revenue) in the third quarter."
        #expect(SpeechTextPolish.polish(text) == "Revenue rose in the third quarter.")
    }

    @Test("heading-less bracket citations are left alone — no section mark, no strip")
    func keepsPlainBrackets() {
        let text = "See item [1] and the note (see above)."
        #expect(SpeechTextPolish.polish(text) == "See item [1] and the note (see above).")
    }

    // MARK: - URLs

    @Test("inline URL collapses to its host without www")
    func urlBecomesHost() {
        let text = "see https://www.weather.com/today?units=c for details"
        #expect(SpeechTextPolish.polish(text) == "see weather.com for details")
    }

    @Test("URL keeps trailing sentence punctuation")
    func urlKeepsPunctuation() {
        let text = "The forecast is at https://met.ie/forecast."
        #expect(SpeechTextPolish.polish(text) == "The forecast is at met.ie.")
    }

    @Test("multiple URLs each collapse to their host")
    func multipleURLs() {
        let text = "Compare http://a.example.com/x and https://b.example.org/y today"
        #expect(SpeechTextPolish.polish(text) == "Compare a.example.com and b.example.org today")
    }

    // MARK: - Curly punctuation

    @Test("curly apostrophes normalize to ASCII so the G2P dictionary hits contractions")
    func curlyApostrophes() {
        #expect(SpeechTextPolish.polish("don\u{2019}t \u{2018}quote\u{2019} me") == "don't 'quote' me")
    }

    // MARK: - Whitespace

    @Test("stripping leaves no doubled spaces or space before punctuation")
    func whitespaceTidy() {
        let text = "Revenue rose [Report §Q3] , then fell."
        #expect(SpeechTextPolish.polish(text) == "Revenue rose, then fell.")
    }

    @Test("newline pile-ups collapse to a paragraph break and ends are trimmed")
    func newlineCollapse() {
        let text = "  First.\n\n\n\nSecond.  "
        #expect(SpeechTextPolish.polish(text) == "First.\n\nSecond.")
    }

    // MARK: - Emoji

    @Test("a trailing emoji is not spoken and leaves no dangling space")
    func trailingEmojiStripped() {
        #expect(SpeechTextPolish.polish("Great job \u{1F389}") == "Great job")
    }

    @Test("an emoji before punctuation leaves the punctuation tight")
    func emojiBeforePunctuation() {
        #expect(SpeechTextPolish.polish("Great job \u{1F389}!") == "Great job!")
    }

    @Test("leading and mid-sentence emoji runs vanish, the words stay")
    func emojiRunsStripped() {
        #expect(SpeechTextPolish.polish("\u{1F525}\u{1F525} hot \u{1F60E} take") == "hot take")
    }

    @Test("ZWJ sequences, skin tones, flags and keycaps strip as one cluster each")
    func emojiClustersStripped() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let wave = "\u{1F44B}\u{1F3FD}"
        let flag = "\u{1F1EE}\u{1F1EA}"
        let keycap = "1\u{FE0F}\u{20E3}"
        #expect(SpeechTextPolish.polish("hi \(family) \(wave) \(flag) \(keycap) done") == "hi done")
    }

    @Test("text-presentation symbols and digits are not emoji — they still speak")
    func textSymbolsSurvive() {
        #expect(SpeechTextPolish.polish("Rooms 1 and 2 \u{00A9} 2026 \u{2192} next") == "Rooms 1 and 2 \u{00A9} 2026 \u{2192} next")
    }

    @Test("bare text-presentation emoji — ticks, faces, suits, weather — are not spoken either")
    func bareTextPresentationEmojiStripped() {
        #expect(SpeechTextPolish.polish("Done \u{2714} sunny \u{2600} \u{263A} \u{2660} ok") == "Done sunny ok")
    }

    @Test("an emoji-only line collapses, the surrounding paragraphs still break")
    func emojiOnlyLine() {
        #expect(SpeechTextPolish.polish("First.\n\u{2728}\n\nSecond.") == "First.\n\nSecond.")
    }

    @Test("emoji inside a fenced code block stay verbatim")
    func emojiInFenceSurvives() {
        let text = "```\nprint(\"\u{1F389}\")\n```"
        #expect(SpeechTextPolish.polish(text) == text)
    }

    // MARK: - Contracts

    @Test("polish is idempotent")
    func idempotent() {
        let text = "Rain [Met §Today] via https://www.met.ie/x.\n\nWeb sources:\n• https://met.ie/x"
        let once = SpeechTextPolish.polish(text)
        #expect(SpeechTextPolish.polish(once) == once)
    }

    @Test("text that is only a sources block polishes to empty — caller guards")
    func onlySourcesBlock() {
        let text = "Web sources:\n• https://a.com\n• https://b.com"
        #expect(SpeechTextPolish.polish(text).isEmpty)
    }

    // MARK: - Markdown flattening (speech never voices markup — the chat

    // pipeline stopped flattening when bubbles learned to RENDER markdown,
    // so the speech lane owns its own flatten now)

    @Test("bold and italic markers are not spoken")
    func flattensEmphasis() {
        let text = "That is **really** important, *honestly*."
        #expect(SpeechTextPolish.polish(text) == "That is really important, honestly.")
    }

    @Test("arithmetic asterisks survive the italic pass")
    func keepsArithmeticAsterisks() {
        let text = "So 2 * 3 is 6."
        #expect(SpeechTextPolish.polish(text) == "So 2 * 3 is 6.")
    }

    @Test("inline code backticks vanish, the code text speaks")
    func flattensInlineCode() {
        let text = "Run `swift test` before you push."
        #expect(SpeechTextPolish.polish(text) == "Run swift test before you push.")
    }

    @Test("heading markers vanish, the heading text speaks")
    func flattensHeadings() {
        let text = "## The plan\nShip it."
        #expect(SpeechTextPolish.polish(text) == "The plan\nShip it.")
    }

    @Test("a markdown link speaks its label, not its URL")
    func flattensLinksToLabel() {
        let text = "See [the forecast](https://met.ie/today) for detail."
        #expect(SpeechTextPolish.polish(text) == "See the forecast for detail.")
    }

    @Test("list bullet markers vanish, the item text speaks")
    func flattensBulletMarkers() {
        let text = "Bring:\n* a coat\n* boots"
        #expect(SpeechTextPolish.polish(text) == "Bring:\na coat\nboots")
    }

    @Test("a thematic break line is silent")
    func dropsThematicBreaks() {
        let text = "Before.\n***\nAfter."
        #expect(SpeechTextPolish.polish(text) == "Before.\n\nAfter.")
    }

    @Test("fenced code passes through verbatim — a shell comment keeps its hash")
    func fencedCodeIsVerbatim() {
        let text = "Install like this:\n```sh\n# deps first\nbrew install *thing*\n```\nDone."
        let polished = SpeechTextPolish.polish(text)
        #expect(polished.contains("# deps first"))
        #expect(polished.contains("brew install *thing*"))
    }

    @Test("markdown flattening is idempotent too")
    func markdownFlattenIdempotent() {
        let text = "**Bold** with `code` and [a link](https://x.com/y).\n## Head"
        let once = SpeechTextPolish.polish(text)
        #expect(SpeechTextPolish.polish(once) == once)
    }

    @Test("CRLF text still pairs its fences — code stays verbatim, prose still flattens")
    func crlfFencesPair() {
        // Swift folds "\r\n" into ONE grapheme: a literal-\n line split sees
        // this as a single line and never finds the fences (the exact bug
        // MessageTextPolish's fencedCodeRanges pins with \.isNewline).
        let text = "Intro **bold**.\r\n```\r\nkeep *ptr* verbatim\r\n```\r\nAfter *italic*."
        let polished = SpeechTextPolish.polish(text)
        #expect(!polished.contains("**"))
        #expect(polished.contains("keep *ptr* verbatim"))
        #expect(polished.contains("After italic."))
    }

    @Test("a line-leading same-line span is prose, not an unclosed fence opener")
    func lineLeadingSameLineSpanIsProse() {
        // CommonMark: a fence opener's info string may not contain backticks —
        // so ```cmd``` on one line is a SPAN. Misreading it as an opener would
        // swallow the rest of the message verbatim, leaving markup spoken.
        let text = "```rm -rf /tmp/cache``` clears the cache.\n\nMore **prose** follows."
        let polished = SpeechTextPolish.polish(text)
        #expect(polished.contains("rm -rf /tmp/cache clears the cache."))
        #expect(polished.contains("More prose follows."))
        #expect(!polished.contains("`"))
    }
}

// Review: Kev + claude-fable-5.1, 2026-09-12 — narration read a "Sources:" list and a
// "Follow-ups:" list verbatim (launch snag list); both trailers now go the way the
// Web-sources block already did. Belt and braces under the stream folders' cut.
extension SpeechTextPolishTests {
    @Test("a trailing Sources block (bulleted or bracketed) is stripped")
    func sourcesBlockStripped() {
        let bulleted = "Tea is ready.\n\nSources:\n- Kitchen notes §brewing\n• Tea §steeping"
        #expect(SpeechTextPolish.polish(bulleted) == "Tea is ready.")
        let inline = "Tea is ready.\nSources: [Kitchen notes §brewing], [Tea §steeping]"
        #expect(SpeechTextPolish.polish(inline) == "Tea is ready.")
    }

    @Test("a trailing follow-ups list in any spelling is never spoken")
    func followUpTrailerStripped() {
        for trailer in ["FOLLOWUPS: [\"More?\"]", "Follow-ups:\n- More?\n- Again?", "**Follow-ups:** More? Again?"] {
            #expect(SpeechTextPolish.polish("Done.\n\n\(trailer)") == "Done.", Comment(rawValue: trailer))
        }
    }

    @Test("a mid-prose 'sources' or 'follow up' survives")
    func midProseSurvives() {
        let text = "Two sources: the river and the well. I'll follow up: tomorrow."
        #expect(SpeechTextPolish.polish(text) == text)
    }

    @Test("a singular trailing Source block is stripped too")
    func singularSourceBlockStripped() {
        let text = "You can walk or cycle.\n\nSource:\n- https://gov.ie/transport"
        #expect(SpeechTextPolish.polish(text) == "You can walk or cycle.")
    }

    @Test("a parenthetical source attribution is stripped from speech")
    func inlineSourceParenStripped() {
        let text = "You can walk or cycle (Source: gov.ie)."
        #expect(SpeechTextPolish.polish(text) == "You can walk or cycle.")
        let via = "Rain expected (Via: met.ie/today)."
        #expect(SpeechTextPolish.polish(via) == "Rain expected.")
        let from = "Population is 5 million (From: cso.ie)."
        #expect(SpeechTextPolish.polish(from) == "Population is 5 million.")
    }

    @Test("prose parens without a source keyword survive")
    func nonSourceParensSurvive() {
        let text = "Cork (an open source project) is written in Swift."
        #expect(SpeechTextPolish.polish(text) == text)
    }
}

// Review: Kev + claude-opus-5.5, 2026-10-15 (pre-push review fold) — the inline attribution strip made its colon
// optional, so ordinary asides that open with "from", "via" or "source" went missing from every spoken answer
// (Mac and phone share this polish) while the screen still showed them.
extension SpeechTextPolishTests {
    @Test("an aside that opens with from / via / source is prose, not an attribution, and is spoken")
    func keywordAsidesSurvive() {
        for text in [
            "The word salary (from the Latin salarium) means salt money.",
            "The festival runs (from 3 to 5 pm) daily.",
            "Take the N40 (via Douglas) to town.",
            "The library (source code is on GitHub) is small.",
        ] {
            #expect(SpeechTextPolish.polish(text) == text, Comment(rawValue: text))
        }
    }

    @Test("without a colon, an attribution goes only when all it names is a site")
    func colonlessSiteAttributionStripped() {
        #expect(SpeechTextPolish.polish("Rain expected (via met.ie).") == "Rain expected.")
        #expect(SpeechTextPolish.polish("Population is 5 million (from cso.ie).") == "Population is 5 million.")
        #expect(SpeechTextPolish.polish("Fares rise in May (source https://nta.ie/fares).") == "Fares rise in May.")
    }

    /// The trailing-block scan used to let every bullet or digit character open a new loop iteration, so a long
    /// run that turned out not to be the answer's tail backtracked exponentially: measured by the review at 0.5 s
    /// for 14 characters and 3.5 s for 16, about 2.5x per character, on the main actor, for every streamed
    /// sentence. A run of 400 would never finish.
    @Test("a long digit or bullet run that is not the answer's tail scans in linear time, and is spoken")
    func sourcesScanIsLinear() {
        let digits = "Call us.\nSources:\n\(String(repeating: "1", count: 400))\nThat's the number."
        #expect(SpeechTextPolish.polish(digits) == digits)
        let bullets = "Odd list.\nSource:\n\(String(repeating: "-x", count: 200))\nThe end."
        #expect(SpeechTextPolish.polish(bullets) == bullets)
        // The linear form still strips what it stripped before.
        #expect(SpeechTextPolish.polish("Answer.\nSources:\n- a\n- b\n") == "Answer.")
        #expect(SpeechTextPolish.polish("Answer.\nSources:\n[1] x\n2. y") == "Answer.")
    }

    /// Auto-speak polishes one streamed sentence at a time, and a model-written trailer arrives as a sentence of its
    /// own. Whole-answer speech falls back to the raw text when polish leaves nothing (an empty utterance would strand
    /// the voice loop's wait); one sentence of a longer answer has nothing waiting on it, so it is simply not spoken.
    @Test("auto-speak's sentence lane: a Source trailer streamed as its own sentence says nothing, never its URL")
    func trailerSentenceIsSilent() {
        var folder = StreamedAnswerFolder()
        for answer in [
            "You can walk or cycle.\n\nSource:\n- https://gov.ie/transport",
            "You can walk or cycle.\n\nSources:\n- https://gov.ie/transport\n- https://nta.ie",
        ] {
            folder = StreamedAnswerFolder()
            var sentences = folder.ingest(answer)
            if let tail = folder.flush() { sentences.append(tail) }
            #expect(sentences.compactMap(SpeechTextPolish.spokenSentence) == ["You can walk or cycle."])
        }
        #expect(SpeechTextPolish.spokenSentence("It's 15 degrees (Source: met.ie).") == "It's 15 degrees.")
        #expect(SpeechTextPolish.spokenSentence("  \n ") == nil)
    }
}

// Review: Kev + claude-fable-5.1, 2026-10-26 — #716: the persona now answers a comparison with a table, and the speech
// lane spoke it pipes, dashes and all; "- " bullets (the commonest list marker the brains write) were read as a dash
// while "* " already vanished. A GFM separator row is silent (with its line break), a row speaks its cells as one
// sentence, dash and plus bullets go the way star bullets did. Fenced code stays verbatim (the karaoke contract).
extension SpeechTextPolishTests {
    @Test("table rows speak as sentences and separator rows are silent — no pipe or dash run survives")
    func tableRowsSpeakAsSentences() {
        let table = "| Drink | Caffeine |\n|---|---|\n| Tea | less |"
        let polished = SpeechTextPolish.polish(table)
        #expect(polished == "Drink, Caffeine.\nTea, less.")
        #expect(!polished.contains("|") && !polished.contains("---"))
        // Aligned, spaced and tight separators all vanish.
        #expect(SpeechTextPolish.polish("| a | b |\n|:--|--:|\n| 1 | 2 |") == "a, b.\n1, 2.")
        #expect(SpeechTextPolish.polish("| a | b |\n| --- | --- |\n| 1 | 2 |") == "a, b.\n1, 2.")
        #expect(SpeechTextPolish.polish("| a | b |\n--- | ---\n| 1 | 2 |") == "a, b.\n1, 2.")
        // A bold cell still flattens, and a cell that already ends a sentence keeps its full stop.
        #expect(SpeechTextPolish.polish("| **Tea** | Less caffeine. |\n|---|---|") == "Tea, Less caffeine.")
        // The prose around the table still speaks, in its place.
        let answer = "Two drinks:\n\n| Drink | Caffeine | Ritual |\n| --- | --- | --- |\n| Tea | less | slow |\n"
            + "| Coffee | more | quick |\n\nI'd take the tea."
        #expect(
            SpeechTextPolish.polish(answer)
                == "Two drinks:\n\nDrink, Caffeine, Ritual.\nTea, less, slow.\nCoffee, more, quick.\n\nI'd take the tea."
        )
        // Idempotent on its own output.
        #expect(SpeechTextPolish.polish(polished) == polished)
    }

    @Test("a pipe inside a fenced code block, and a pipe mid-prose, stay verbatim")
    func pipesOutsideTablesSurvive() {
        let code = "Pipe it:\n```sh\ncat a | grep b\n|---|\n```\nDone."
        let polished = SpeechTextPolish.polish(code)
        #expect(polished.contains("cat a | grep b"))
        #expect(polished.contains("|---|"))
        // A pipe in a sentence is not a row: only a line that OPENS with one is.
        #expect(SpeechTextPolish.polish("Either A | B works.") == "Either A | B works.")
    }

    @Test("dash and plus bullets vanish like star bullets; hyphens, negatives and numbered steps survive")
    func dashBulletsVanishLikeStarBullets() {
        #expect(SpeechTextPolish.polish("Bring:\n- a coat\n- boots") == "Bring:\na coat\nboots")
        #expect(SpeechTextPolish.polish("Bring:\n+ a coat\n+ boots") == "Bring:\na coat\nboots")
        #expect(SpeechTextPolish.polish("Bring:\n  - a coat\n  - boots") == "Bring:\na coat\nboots")
        // A hyphenated word, a leading negative number and a numbered how-to all read as written.
        #expect(SpeechTextPolish.polish("A well-known trick.") == "A well-known trick.")
        #expect(SpeechTextPolish.polish("Cold:\n-5 degrees tonight.") == "Cold:\n-5 degrees tonight.")
        #expect(SpeechTextPolish.polish("1. Boil the water.\n2. Pour it over.") == "1. Boil the water.\n2. Pour it over.")
        // Still: a thematic break is silent and the fence is verbatim (the pinned cases).
        #expect(SpeechTextPolish.polish("Before.\n---\nAfter.") == "Before.\n\nAfter.")
        #expect(SpeechTextPolish.polish("```\n- not a bullet\n```") == "```\n- not a bullet\n```")
    }

    @Test("a bold Sources label still heads a stripped block — the strip runs before the flatten now")
    func boldSourcesBlockStripped() {
        // The flatten used to unwrap **Sources:** before the block scan saw it; the scan runs first since #716
        // (it keys on the "- " markers the flatten now removes), so the label takes its own bold.
        #expect(SpeechTextPolish.polish("Tea is ready.\n\n**Sources:**\n- Kitchen notes §brewing") == "Tea is ready.")
        #expect(SpeechTextPolish.polish("Tea is ready.\n\nSources:\n- Kitchen notes §brewing\n• Tea §steeping") == "Tea is ready.")
    }
}

// Review: Kev + claude-fable-5.1, 2026-10-26 (pre-push review fold) — #716, the pins the review asked for. A CRLF table
// keeps its line breaks; the per-sentence lane (what auto-speak calls) says nothing for a separator row and a sentence
// for a row; a row that a sentence-final full stop in a cell splits in two still speaks no pipe (a line that CLOSES
// with a pipe is a row too); the edge-less GFM row is the deliberate gap, pinned; a dash list after a blank line keeps
// its paragraph break (the bullet rule's `\s` used to eat it); the Sources strip, moved ahead of the flatten, takes
// every label the screen-side cut takes, the app's Web sources block after a model's Sources list still goes, and an
// inline attribution still goes once the link or emphasis inside it is unwrapped (the strip is back after the flatten).
// Review: Kev + claude-opus-5.5, 2026-10-26 (second review fold) — `strandedPipeSaysNothing`: the empty-cells guard in
// `spokenRow` is what keeps a pipe the sentence fold strands ("|", "||", a "|" line above a separator) from speaking as
// a lone ".". Red with the guard removed, green with it; the folder-driven case pins the held pipe on a real stream.
extension SpeechTextPolishTests {
    @Test("a CRLF table keeps its line breaks and speaks no pipe or dash run")
    func crlfTableRows() {
        let polished = SpeechTextPolish.polish("| a | b |\r\n|---|---|\r\n| 1 | 2 |")
        #expect(!polished.contains("|") && !polished.contains("---"))
        #expect(polished == "a, b.\r\n1, 2.")
    }

    @Test("the sentence lane: a separator row says nothing, a row speaks as a sentence")
    func sentenceLaneTableFragments() {
        #expect(SpeechTextPolish.spokenSentence("|---|---|") == nil)
        #expect(SpeechTextPolish.spokenSentence("| :-- | --: |") == nil)
        #expect(SpeechTextPolish.spokenSentence("| Tea | less |") == "Tea, less.")
    }

    /// A row whose cell ends a sentence is cut by the fold right after that full stop, and what is left is a
    /// stranded pipe: "| Drink | Note." then "|\n|---|---|…" for a header, "| Tea | Calm." then " |" for a body row.
    /// A row with no cells says nothing — without the empty-cells guard the pipe would speak as a lone ".".
    @Test("a stranded pipe left by the sentence fold says nothing, never a lone full stop")
    func strandedPipeSaysNothing() {
        #expect(SpeechTextPolish.polish("|") == "")
        #expect(SpeechTextPolish.polish("| |") == "")
        #expect(SpeechTextPolish.spokenSentence("|") == nil)
        #expect(SpeechTextPolish.spokenSentence("||") == nil)
        #expect(SpeechTextPolish.polish("|\n|---|---|\n| Tea | x |") == "Tea, x.")
        // Folder-driven: the last cell of the last row ends in a full stop, so the fold strands its closing pipe.
        var folder = StreamedAnswerFolder()
        var sentences = folder.ingest("| Drink | Notes |\n|---|---|\n| Tea | Calm. |\n\nI'd take the tea.")
        if let tail = folder.flush() { sentences.append(tail) }
        let spoken = sentences.compactMap(SpeechTextPolish.spokenSentence).joined(separator: " ")
        #expect(!spoken.contains("|"))
        #expect(!spoken.hasPrefix("."))
        #expect(!spoken.contains(" . "))
        #expect(spoken == "Drink, Notes.\nTea, Calm. I'd take the tea.")
    }

    /// Auto-speak folds the stream into sentences at a full stop plus whitespace, so a cell that ends a sentence cuts
    /// its row in two: the tail has no leading pipe. It closes with one, and that is a row as well.
    @Test("a row cut in two by a full stop in a cell still speaks no pipe: a line that closes with a pipe is a row")
    func rowSplitBySentenceFoldSpeaksNoPipe() {
        var folder = StreamedAnswerFolder()
        let table = "| Drink | Notes |\n|---|---|\n| Tea | Calm. Slow |\n| Coffee | Quick |"
        var sentences = folder.ingest(table)
        if let tail = folder.flush() { sentences.append(tail) }
        #expect(sentences.count == 2)
        let spoken = sentences.compactMap(SpeechTextPolish.spokenSentence).joined(separator: " ")
        #expect(!spoken.contains("|"))
        #expect(spoken == "Drink, Notes.\nTea, Calm. Slow.\nCoffee, Quick.")
        #expect(SpeechTextPolish.polish("Slow |") == "Slow.")
    }

    @Test("the known gap, pinned: an edge-less GFM row keeps its pipes")
    func edgelessRowIsTheKnownGap() {
        // Valid GFM, rare from the brains: no leading or trailing pipe, so the row rule never sees it (the
        // separator still goes). Deliberate — a pipe mid-prose ("Either A | B works.") must survive, and nothing
        // tells the two apart without reading the table around them.
        #expect(SpeechTextPolish.polish("a | b\n--- | ---\n1 | 2") == "a | b\n1 | 2")
    }

    @Test("a dash list after a blank line keeps its paragraph break, and a lone dash line is not a bullet")
    func dashListKeepsParagraphBreak() {
        #expect(SpeechTextPolish.polish("Bring:\n\n- a coat\n- boots") == "Bring:\n\na coat\nboots")
        #expect(SpeechTextPolish.polish("Bring:\n\n* a coat\n* boots") == "Bring:\n\na coat\nboots")
        #expect(SpeechTextPolish.polish("A\n-\nB") == "A\n-\nB")
    }

    @Test("every Sources label the screen-side cut takes is stripped ahead of the flatten")
    func sourcesLabelsMatchTheScreenCut() {
        for label in ["Sources:", "**Sources:**", "**Sources**:", "*Sources:*", "## Sources:", "Source:", "__Sources__:"] {
            #expect(
                SpeechTextPolish.polish("Tea is ready.\n\n\(label)\n- Kitchen notes §brewing\n- Tea §steeping") == "Tea is ready.",
                Comment(rawValue: label)
            )
        }
    }

    @Test("a model's Sources list followed by the app's Web sources block: both go")
    func sourcesThenWebSourcesBothGo() {
        #expect(SpeechTextPolish.polish("Answer.\n\nSources:\n- a\n\nWeb sources:\n• b") == "Answer.")
        #expect(SpeechTextPolish.polish("Answer.\n\n**Sources:**\n- [a](https://a.ie)\n\nWeb sources:\n• [b](https://b.ie)") == "Answer.")
    }

    @Test("an inline attribution still goes once the link or emphasis inside it is unwrapped")
    func inlineAttributionAfterFlatten() {
        #expect(SpeechTextPolish.polish("It's 15 degrees (Source: [met.ie](https://met.ie/x)).") == "It's 15 degrees.")
        #expect(SpeechTextPolish.polish("It's 15 degrees (*Source: gov.ie*).") == "It's 15 degrees.")
        #expect(SpeechTextPolish.polish("It's 15 degrees (**Source:** gov.ie).") == "It's 15 degrees.")
    }
}
