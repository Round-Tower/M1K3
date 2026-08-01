//
//  ChatMarkdownBlockTests.swift
//  M1K3ChatTests
//
//  Signed: Kev + claude-sonnet-5, 2026-07-22, Confidence 0.85, Prior: Unknown

import Foundation
@testable import M1K3Chat
import Testing

struct ChatMarkdownBlockTests {
    @Test("empty and whitespace-only text yield no blocks")
    func empty() {
        #expect(ChatMarkdownParser.parse("").isEmpty)
        #expect(ChatMarkdownParser.parse("   \n\n  ").isEmpty)
    }

    @Test("a heading and a following paragraph split into two blocks")
    func headingAndParagraph() {
        let blocks = ChatMarkdownParser.parse("# Title\n\nBody text")
        #expect(blocks.count == 2)
        guard case let .heading(level, text) = blocks[0] else { Issue.record("expected heading"); return }
        #expect(level == 1)
        #expect(String(text.characters) == "Title")
        guard case let .paragraph(body) = blocks[1] else { Issue.record("expected paragraph"); return }
        #expect(String(body.characters) == "Body text")
    }

    @Test("heading levels 1-6 all resolve")
    func headingLevels() {
        for level in 1 ... 6 {
            let marker = String(repeating: "#", count: level)
            let blocks = ChatMarkdownParser.parse("\(marker) Heading\nbody")
            guard case let .heading(parsedLevel, _) = blocks.first else { Issue.record("expected heading"); continue }
            #expect(parsedLevel == level)
        }
    }

    @Test("plain prose with no markup is one paragraph, byte-identical text")
    func plainProse() {
        let text = "The seal failed under load."
        let blocks = ChatMarkdownParser.parse(text)
        #expect(blocks.count == 1)
        guard case let .paragraph(body) = blocks[0] else { Issue.record("expected paragraph"); return }
        #expect(String(body.characters) == text)
    }

    @Test("bold/italic/inline-code markers vanish from the plain text but the run survives")
    func inlineEmphasisStripsMarkersFromPlainText() {
        let blocks = ChatMarkdownParser.parse("Some **bold** and *italic* and `code`.")
        #expect(blocks.count == 1)
        guard case let .paragraph(body) = blocks[0] else { Issue.record("expected paragraph"); return }
        #expect(String(body.characters) == "Some bold and italic and code.")
    }

    @Test("citation tokens (no following parenthesis) are not links and pass through untouched")
    func citationTokensSurvive() {
        let text = "Clean the line (ICH-Q7 §5.2) and [Plant Notes §3.2 Seals] says so."
        let blocks = ChatMarkdownParser.parse(text)
        #expect(blocks.count == 1)
        guard case let .paragraph(body) = blocks[0] else { Issue.record("expected paragraph"); return }
        #expect(String(body.characters) == text)
    }

    @Test("a fenced code block with a language tag becomes its own block, trailing newline trimmed")
    func fencedCodeWithLanguage() {
        let blocks = ChatMarkdownParser.parse("Here:\n\n```swift\nlet x = 1\nprint(x)\n```\n\nDone.")
        #expect(blocks.count == 3)
        guard case let .codeBlock(language, code) = blocks[1] else { Issue.record("expected codeBlock"); return }
        #expect(language == "swift")
        #expect(code == "let x = 1\nprint(x)")
    }

    @Test("a fence with no language tag has a nil language")
    func fencedCodeNoLanguage() {
        let blocks = ChatMarkdownParser.parse("```\nplain code\n```")
        #expect(blocks.count == 1)
        guard case let .codeBlock(language, code) = blocks[0] else { Issue.record("expected codeBlock"); return }
        #expect(language == nil)
        #expect(code == "plain code")
    }

    @Test("an unclosed fence (max-token truncation mid-stream) still becomes a code block to the end")
    func unclosedFenceStreaming() {
        let blocks = ChatMarkdownParser.parse("Here:\n```swift\nlet x = 1\nprint(x)")
        #expect(blocks.count == 2)
        guard case .paragraph = blocks[0] else { Issue.record("expected paragraph"); return }
        guard case let .codeBlock(language, code) = blocks[1] else { Issue.record("expected codeBlock"); return }
        #expect(language == "swift")
        #expect(code == "let x = 1\nprint(x)")
    }

    @Test("a `# comment` line inside a fence is code, never mistaken for a heading")
    func hashCommentInsideFenceIsNotAHeading() {
        let blocks = ChatMarkdownParser.parse("```python\n# reverse a string\ndef rev(s):\n    return s[::-1]\n```")
        #expect(blocks.count == 1)
        guard case let .codeBlock(language, code) = blocks[0] else { Issue.record("expected codeBlock"); return }
        #expect(language == "python")
        #expect(code.hasPrefix("# reverse a string"))
    }

    @Test("bullet list items each become their own block with a nil ordinal")
    func bulletList() {
        let blocks = ChatMarkdownParser.parse("- one\n- two\n- three")
        #expect(blocks.count == 3)
        for (index, expected) in ["one", "two", "three"].enumerated() {
            guard case let .listItem(ordinal, text) = blocks[index] else { Issue.record("expected listItem"); continue }
            #expect(ordinal == nil)
            #expect(String(text.characters) == expected)
        }
    }

    @Test("numbered list items carry their 1-based ordinal")
    func numberedList() {
        let blocks = ChatMarkdownParser.parse("1. one\n2. two")
        #expect(blocks.count == 2)
        guard case let .listItem(firstOrdinal, _) = blocks[0] else { Issue.record("expected listItem"); return }
        guard case let .listItem(secondOrdinal, _) = blocks[1] else { Issue.record("expected listItem"); return }
        #expect(firstOrdinal == 1)
        #expect(secondOrdinal == 2)
    }

    @Test("a block quote becomes its own block")
    func blockquote() {
        let blocks = ChatMarkdownParser.parse("> quoted text")
        #expect(blocks.count == 1)
        guard case let .blockquote(text) = blocks[0] else { Issue.record("expected blockquote"); return }
        #expect(String(text.characters) == "quoted text")
    }

    @Test("a thematic break (---) is its own block between two paragraphs")
    func thematicBreak() {
        let blocks = ChatMarkdownParser.parse("Intro\n\n---\n\nBody")
        #expect(blocks.count == 3)
        guard case .paragraph = blocks[0] else { Issue.record("expected paragraph"); return }
        #expect(blocks[1] == .thematicBreak)
        guard case .paragraph = blocks[2] else { Issue.record("expected paragraph"); return }
    }

    @Test("a real markdown link carries its URL on the run")
    func realLinkCarriesURL() {
        let blocks = ChatMarkdownParser.parse("[AccuWeather](https://accuweather.com/boston)")
        guard case let .paragraph(text) = blocks.first else { Issue.record("expected paragraph"); return }
        let link = text.runs.first?.link
        #expect(link?.absoluteString == "https://accuweather.com/boston")
    }

    @Test("a code fence nested under a bullet is a codeBlock, not swallowed into the list item's text")
    func fenceNestedUnderBullet() {
        let blocks = ChatMarkdownParser.parse("* step one:\n    ```swift\n    let s = \"x\"\n    ```\nand done.")
        #expect(blocks.contains { if case .codeBlock = $0 { true } else { false } })
    }

    @Test("a table becomes ONE table block, not one paragraph per cell (the live-testing catch)")
    func tableBecomesOneBlock() {
        let md = """
        | Feature | Capability | Status |
        | --- | --- | --- |
        | Markdown Rendering | High | Sharp |
        | Code Blocks | Yes | Great |
        """
        let blocks = ChatMarkdownParser.parse(md)
        #expect(blocks.count == 1)
        guard case let .table(header, rows) = blocks[0] else { Issue.record("expected table"); return }
        #expect(header.map { String($0.characters) } == ["Feature", "Capability", "Status"])
        #expect(rows.count == 2)
        #expect(rows[0].map { String($0.characters) } == ["Markdown Rendering", "High", "Sharp"])
        #expect(rows[1].map { String($0.characters) } == ["Code Blocks", "Yes", "Great"])
    }

    @Test("a styled run inside a cell stays ONE cell — runs merge per (header,row,col)")
    func styledCellStaysOneCell() {
        // A cell containing **bold** or `code` arrives as MULTIPLE runs sharing
        // one (isHeader, rowIndex, columnIndex) key; capturing one cell per run
        // would split it into phantom columns.
        let md = """
        | Feature | Status |
        | --- | --- |
        | **Markdown** rendering | `done` now |
        """
        let blocks = ChatMarkdownParser.parse(md)
        #expect(blocks.count == 1)
        guard case let .table(header, rows) = blocks[0] else { Issue.record("expected table"); return }
        #expect(header.map { String($0.characters) } == ["Feature", "Status"])
        #expect(rows.count == 1)
        #expect(rows[0].map { String($0.characters) } == ["Markdown rendering", "done now"])
    }

    @Test("a table sits between two ordinary paragraphs without swallowing them")
    func tableBetweenParagraphs() {
        let md = "Intro line\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\nOutro line"
        let blocks = ChatMarkdownParser.parse(md)
        #expect(blocks.count == 3)
        guard case .paragraph = blocks[0] else { Issue.record("expected paragraph"); return }
        guard case let .table(header, rows) = blocks[1] else { Issue.record("expected table"); return }
        #expect(header.map { String($0.characters) } == ["A", "B"])
        #expect(rows.map { row in row.map { String($0.characters) } } == [["1", "2"]])
        guard case .paragraph = blocks[2] else { Issue.record("expected paragraph"); return }
    }
}
