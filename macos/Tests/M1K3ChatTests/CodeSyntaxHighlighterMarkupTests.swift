//
//  CodeSyntaxHighlighterMarkupTests.swift
//  M1K3ChatTests
//
//  HTML and CSS rules for the code panel (1.6: code opens beside the chat).
//
//  Signed: Kev + claude-opus-5-5, 2026-11-23, Confidence 0.8, Prior: Unknown (new file)

import Foundation
@testable import M1K3Chat
import Testing

struct CodeSyntaxHighlighterMarkupTests {
    @Test("html: tags are keywords, attributes are types, values are strings, comments are comments")
    func htmlBasics() {
        let tokens = CodeSyntaxHighlighter.tokenize(
            "<!-- hi --><a href=\"x\" class='y'>Go</a>", language: "html"
        )
        #expect(tokens.contains(CodeToken(kind: .comment, text: "<!-- hi -->")))
        #expect(tokens.contains(where: { $0.kind == .keyword && $0.text.contains("<a") }))
        #expect(tokens.contains(CodeToken(kind: .type, text: "href")))
        #expect(tokens.contains(CodeToken(kind: .string, text: "\"x\"")))
        #expect(tokens.contains(CodeToken(kind: .string, text: "'y'")))
        #expect(tokens.contains(CodeToken(kind: .plain, text: "Go")))
    }

    @Test("html: tokens reassemble to the exact source")
    func htmlRoundTrip() {
        let source = "<!DOCTYPE html>\n<html lang=\"en\">\n<body>\n  <p>1 < 2 & 3</p>\n</body>\n</html>\n"
        let joined = CodeSyntaxHighlighter.tokenize(source, language: "html").map(\.text).joined()
        #expect(joined == source)
    }

    @Test("html: a style element's body is highlighted as css")
    func htmlEmbeddedCSS() {
        let tokens = CodeSyntaxHighlighter.tokenize("<style>p { color: red; }</style>", language: "htm")
        #expect(tokens.contains(where: { $0.kind == .keyword && $0.text == "color" }))
    }

    @Test("html: a script element's body is highlighted as javascript")
    func htmlEmbeddedJS() {
        let tokens = CodeSyntaxHighlighter.tokenize("<script>const a = 1;</script>", language: "html")
        #expect(tokens.contains(where: { $0.kind == .keyword && $0.text == "const" }))
    }

    @Test("html: unterminated input keeps every character")
    func htmlUnterminated() {
        for source in ["<div class=\"x", "<!-- never closed", "<", "<style>a{", "a < b", "<script>let"] {
            let joined = CodeSyntaxHighlighter.tokenize(source, language: "html").map(\.text).joined()
            #expect(joined == source)
        }
    }

    @Test("css: properties and at-rules are keywords, values numbers and strings, comments comments")
    func cssBasics() {
        let tokens = CodeSyntaxHighlighter.tokenize(
            "/* c */\n@media (min-width: 600px) {\n  .a:hover { color: #fff; margin: 0 4px; content: \"x\"; }\n}",
            language: "css"
        )
        #expect(tokens.contains(CodeToken(kind: .comment, text: "/* c */")))
        #expect(tokens.contains(CodeToken(kind: .keyword, text: "@media")))
        #expect(tokens.contains(where: { $0.kind == .keyword && $0.text == "color" }))
        #expect(tokens.contains(CodeToken(kind: .number, text: "#fff")))
        #expect(tokens.contains(CodeToken(kind: .number, text: "4px")))
        #expect(tokens.contains(CodeToken(kind: .string, text: "\"x\"")))
    }

    @Test("css: a selector's pseudo-class is not mistaken for a property")
    func cssSelectorColon() {
        let tokens = CodeSyntaxHighlighter.tokenize("a:hover { color: red }", language: "css")
        #expect(!tokens.contains(where: { $0.kind == .keyword && $0.text == "hover" }))
        #expect(!tokens.contains(where: { $0.kind == .keyword && $0.text == "a" }))
    }

    @Test("css: tokens reassemble to the exact source, even when unterminated")
    func cssRoundTrip() {
        for source in ["body { margin: 0; }\n", "/* open", "a { content: \"x", "{", "}}", "@import url(x);"] {
            let joined = CodeSyntaxHighlighter.tokenize(source, language: "css").map(\.text).joined()
            #expect(joined == source)
        }
    }
}
