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

    // MARK: - Typed answer blocks (#717)

    @Test("a steps block speaks as sentences, never as JSON")
    func typedStepsSpeakAsSentences() {
        let text = "Here's how:\n```m1k3-steps\n{\"steps\": [\"Loosen the **nut**\", \"Lift the cover.\"]}\n```\nThat's it."
        let polished = SpeechTextPolish.polish(text)
        #expect(polished == "Here's how:\nStep 1: Loosen the nut. Step 2: Lift the cover.\nThat's it.")
        #expect(!polished.contains("{"))
        #expect(!polished.contains("steps\""))
        #expect(SpeechTextPolish.polish(polished) == polished)
    }

    @Test("a lone closed typed fence (what the sentence folder emits) speaks its sentences")
    func typedFenceSentenceSpeaks() {
        let chunk = "```m1k3-choices\n{\"prompt\": \"Which engine?\", \"options\": [\"Lil\", \"Big\", \"Mini\"]}\n```"
        #expect(SpeechTextPolish.spokenSentence(chunk) == "Which engine? Options: Lil, Big, or Mini.")
    }

    @Test("a malformed or unclosed typed fence says it's on screen, on every lane, never its JSON")
    func malformedTypedFenceSaysOnScreen() {
        // Voice mode speaks each folded chunk through speak(), which reads the RAW
        // chunk when polish returns "" — so a lone bad fence must polish to words.
        let lone = "```m1k3-steps\n{\"steps\": [1, 2]}\n```"
        #expect(SpeechTextPolish.polish(lone) == "I've put that on screen.")
        #expect(SpeechTextPolish.spokenSentence(lone) == "I've put that on screen.")
        #expect(SpeechTextPolish.spokenSentence("```m1k3-steps\n{\"steps\": [\"Lo") == "I've put that on screen.")
        let answer = "Try this.\n```m1k3-choices\n{\"prompt\": \"Pick\"}\n```"
        #expect(SpeechTextPolish.polish(answer) == "Try this.\nI've put that on screen.")
    }

    @Test("a choices block before a FOLLOWUPS trailer speaks the options and not the trailer")
    func typedChoicesBeforeFollowUps() {
        let text = "Pick one:\n```m1k3-choices\n{\"prompt\": \"Tea or coffee?\", \"options\": [\"Tea\", \"Coffee\"]}\n```\n"
            + "FOLLOWUPS: [\"How strong?\"]"
        #expect(SpeechTextPolish.polish(text) == "Pick one:\nTea or coffee? Options: Tea or Coffee.")
    }

    @Test("an ordinary fence that merely mentions a typed tag is still read verbatim")
    func ordinaryFenceWithTypedTagVerbatim() {
        let text = "The format:\n````\n```m1k3-steps\n{\"steps\": [\"One\"]}\n```\n````\nDone."
        let polished = SpeechTextPolish.polish(text)
        #expect(polished.contains("{\"steps\": [\"One\"]}"))
    }

    // Review: Kev + claude-opus-5.5, 2026-10-27 (code-quality review fold) — the typed blocks beside an
    // ordinary fence (where the segmenter's fence rules and fencedCodeRanges must agree), a block's words
    // through the later passes (URL, emoji, the name), and the fixed point on every typed output.
    @Test("typed blocks around an ordinary fence: both spoken, the code between them verbatim")
    func typedBlocksAroundOrdinaryFence() {
        let text = "First:\n```m1k3-steps\n{\"steps\": [\"Boil\"]}\n```\nCode:\n```swift\nlet p = *ptr*\n```\n"
            + "Then:\n```m1k3-choices\n{\"prompt\": \"Milk?\", \"options\": [\"Yes\", \"No\"]}\n```"
        let polished = SpeechTextPolish.polish(text)
        #expect(polished.contains("```swift\nlet p = *ptr*\n```"))
        #expect(polished.hasPrefix("First:\nStep 1: Boil.\n"))
        #expect(polished.hasSuffix("Then:\nMilk? Options: Yes or No."))
        #expect(!polished.contains("m1k3-"))
        #expect(SpeechTextPolish.polish(polished) == polished)
    }

    @Test("a block's words take the later passes like prose: a URL to its host, no emoji, the name as Mike")
    func typedBlockWordsArePolished() {
        let text = "```m1k3-steps\n"
            + "{\"steps\": [\"Open https://www.example.org/setup 🎉\", \"Ask **M1K3** to help.\"]}\n```"
        let polished = SpeechTextPolish.polish(text)
        #expect(polished == "Step 1: Open example.org. Step 2: Ask Mike to help.")
        #expect(SpeechTextPolish.polish(polished) == polished)
    }

    @Test("one pass is a fixed point for every typed output: sentences and the on-screen line")
    func typedOutputsAreFixedPoints() {
        for text in [
            "```m1k3-choices\n{\"prompt\": \"Which engine?\", \"options\": [\"Lil\", \"Big\"]}\n```",
            "```m1k3-steps\n{\"steps\": [1]}\n```",
            "Before.\n```m1k3-steps\n{\"steps\": [\"Lo",
        ] {
            let once = SpeechTextPolish.polish(text)
            #expect(SpeechTextPolish.polish(once) == once, "\(text.debugDescription)")
        }
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
