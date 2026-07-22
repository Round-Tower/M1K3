//
//  MessageTextPolishTests.swift
//  M1K3ChatTests
//
//  As of the markdown/code-highlighting pass (2026-07-22), ReadingText renders
//  real markdown (ChatMarkdownParser) instead of plain flattened text, so this
//  file no longer flattens **bold**/*italic*/`code`/#headings/bullets/links —
//  it only tidies blank-line pile-ups, staying fence/artifact-safe. These
//  tests were rewritten to pin the NEW contract (markup survives byte-for-
//  byte); see git history for the old flattening-era pins.
//
//  Signed: Kev + claude-sonnet-5, 2026-07-22, Confidence 0.85, Prior: Unknown

import Foundation
@testable import M1K3Chat
import Testing

struct MessageTextPolishTests {
    @Test("markdown markup survives untouched — bold, italic, links, bullets, headings, inline code")
    func markdownSurvives() {
        #expect(MessageTextPolish.polish("**AccuWeather:** sunny") == "**AccuWeather:** sunny")
        #expect(MessageTextPolish.polish("the *quick* brown fox") == "the *quick* brown fox")
        #expect(MessageTextPolish.polish("area = 2 * 3 * 4") == "area = 2 * 3 * 4")
        #expect(
            MessageTextPolish.polish("[AccuWeather](https://accuweather.com/boston)")
                == "[AccuWeather](https://accuweather.com/boston)"
        )
        #expect(MessageTextPolish.polish("* first\n* second") == "* first\n* second")
        #expect(MessageTextPolish.polish("run `swift test` now") == "run `swift test` now")
        #expect(MessageTextPolish.polish("## Forecast\ndetails") == "## Forecast\ndetails")
    }

    @Test("a thematic-break line (*** / --- / ___) is left alone — the renderer draws it as a divider")
    func thematicBreakSurvives() {
        #expect(MessageTextPolish.polish("Intro\n\n***\n\nBody") == "Intro\n\n***\n\nBody")
        #expect(MessageTextPolish.polish("Intro\n\n---\n\nBody") == "Intro\n\n---\n\nBody")
    }

    @Test("citation tokens are NOT links and survive untouched")
    func preservesCitations() {
        let text = "Clean the line (ICH-Q7 §5.2 Cleaning) and [Plant Notes §3.2 Seals] says so."
        #expect(MessageTextPolish.polish(text) == text)
    }

    @Test("newline pile-ups collapse and ends are trimmed (the Web sources gap)")
    func whitespaceTidy() {
        let text = "Check these.\n\n\n\n\n\nWeb sources:\n• https://a\n\n"
        #expect(MessageTextPolish.polish(text) == "Check these.\n\nWeb sources:\n• https://a")
    }

    @Test("plain text passes through unchanged")
    func plainText() {
        let text = "The seal failed under load.\n\nWeb sources:\n• https://a"
        #expect(MessageTextPolish.polish(text) == text)
    }

    @Test("fenced code blocks survive verbatim — heading/comment lines, backticks, bold")
    func preservesFencedCode() {
        let html = "Here you go:\n\n```html\n<!DOCTYPE html>\n<h1>Hi</h1>\n```\n\nThat's it."
        let out = MessageTextPolish.polish(html)
        #expect(out.contains("```html"))
        #expect(out.contains("<!DOCTYPE html>"))
        #expect(out.contains("<h1>Hi</h1>"))
    }

    @Test("a `# comment` line inside a code fence is NOT eaten as a heading")
    func preservesCodeComments() {
        let pySnippet = "```python\n# reverse a string\ndef rev(s):\n    return s[::-1]\n```"
        #expect(MessageTextPolish.polish(pySnippet) == pySnippet)
    }

    @Test("prose around a fence is untouched; the fence is untouched too")
    func fenceAndSurroundingProseBothSurvive() {
        let text = "**Note:** run this:\n\n```\nls -la\n```\n\nand `done`."
        #expect(MessageTextPolish.polish(text) == text)
    }

    @Test("a fence whose body mentions ``` mid-line does not split early")
    func fenceBodyMentioningBackticksMidLine() {
        // The old non-greedy regex paired the opener with the INLINE ``` and the
        // rest of the code fell through to prose polishing (# lines eaten).
        let text = "```\nuse ``` to open a fence\n# keep this comment\n```"
        #expect(MessageTextPolish.polish(text) == text)
    }

    @Test("an unclosed fence (max-token truncation) is preserved verbatim to the end")
    func unclosedFencePreservedVerbatim() {
        let text = "Here you **go**:\n```swift\n# a comment\nlet x = 1"
        #expect(MessageTextPolish.polish(text) == text)
    }

    @Test("a longer outer fence (````) keeps inner ``` fences whole — run-length pairing")
    func longerOuterFencePreservesInnerFences() {
        let text = "````markdown\n```\ninner code\n```\n````"
        #expect(MessageTextPolish.polish(text) == text)
    }

    @Test("a LINE-LEADING same-line ```code``` span is left alone — the renderer styles it as inline code")
    func lineLeadingSameLineSpanSurvives() {
        let text = "```rm -rf /tmp/cache``` clears the cache.\n\nMore **prose** follows."
        #expect(MessageTextPolish.polish(text) == text)
    }

    @Test("a fence indented 4+ spaces (nested under a bullet) is still preserved verbatim")
    func deeplyIndentedFencePreserved() {
        // CommonMark calls a 4-space-indented ``` an indented code block, not a
        // fence — but this file's job is "don't mangle code", so ANY-indent
        // fences are treated as fences (models nest them under list items).
        let text = "* step one:\n    ```swift\n    let s = \"**not bold**\"\n    ```\nand `done`."
        #expect(MessageTextPolish.polish(text) == text)
    }

    @Test("CRLF line endings pair fences correctly (Windows-origin pastes)")
    func crlfFences() {
        // The trailing \r lands inside the scanner's "line" content; it must
        // still open on the backtick run and close on the backticks-only line
        // (\r counts as whitespace). Pinned by design, not by accident.
        let text = "**Note:**\r\n```\r\n# comment\r\nls\r\n```\r\ndone `now`."
        #expect(MessageTextPolish.polish(text) == text)
    }

    @Test("an unclosed <artifact> (truncation) is preserved verbatim to the end")
    func unclosedArtifactPreservedVerbatim() {
        let text = "Intro *here*\n<artifact title=\"Doc\">\n# Heading **kept**"
        #expect(MessageTextPolish.polish(text) == text)
    }
}
