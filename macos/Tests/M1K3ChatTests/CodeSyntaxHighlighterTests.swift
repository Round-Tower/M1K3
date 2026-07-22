//
//  CodeSyntaxHighlighterTests.swift
//  M1K3ChatTests
//
//  Signed: Kev + claude-sonnet-5, 2026-07-22, Confidence 0.8, Prior: Unknown

import Foundation
@testable import M1K3Chat
import Testing

struct CodeSyntaxHighlighterTests {
    @Test("nil language returns the whole code as one plain token")
    func nilLanguage() {
        let tokens = CodeSyntaxHighlighter.tokenize("no highlighting please", language: nil)
        #expect(tokens == [CodeToken(kind: .plain, text: "no highlighting please")])
    }

    @Test("an unrecognized language returns the whole code as one plain token, never crashes")
    func unrecognizedLanguage() {
        let tokens = CodeSyntaxHighlighter.tokenize("some random text", language: "prolog")
        #expect(tokens == [CodeToken(kind: .plain, text: "some random text")])
    }

    @Test("empty code returns no tokens regardless of language")
    func emptyCode() {
        #expect(CodeSyntaxHighlighter.tokenize("", language: "swift").isEmpty)
        #expect(CodeSyntaxHighlighter.tokenize("", language: nil).isEmpty)
    }

    @Test("swift: line comment, keyword, and string are each their own token kind")
    func swiftBasics() {
        let tokens = CodeSyntaxHighlighter.tokenize(
            "// greet\nfunc greet() -> String {\n    return \"hi\"\n}", language: "swift"
        )
        #expect(tokens.contains(CodeToken(kind: .comment, text: "// greet")))
        #expect(tokens.contains(where: { $0.kind == .keyword && $0.text == "func" }))
        #expect(tokens.contains(where: { $0.kind == .keyword && $0.text == "return" }))
        #expect(tokens.contains(CodeToken(kind: .string, text: "\"hi\"")))
        #expect(tokens.contains(CodeToken(kind: .type, text: "String")))
    }

    @Test("swift: a language alias (an uppercase Type name) is recognized case-insensitively via the tag")
    func languageAliasCaseInsensitive() {
        let tokens = CodeSyntaxHighlighter.tokenize("let x = 1", language: "Swift")
        #expect(tokens.contains(where: { $0.kind == .keyword && $0.text == "let" }))
    }

    @Test("swift: an escaped quote inside a string does not end it early")
    func swiftEscapedQuote() {
        let tokens = CodeSyntaxHighlighter.tokenize(#"let s = "a \"quoted\" word""#, language: "swift")
        #expect(tokens.contains(CodeToken(kind: .string, text: #""a \"quoted\" word""#)))
    }

    @Test("python: hash comments and keywords are recognized; bare capitalized words are NOT typed")
    func pythonBasics() {
        let tokens = CodeSyntaxHighlighter.tokenize(
            "# reverse a string\ndef rev(s):\n    return s[::-1]", language: "python"
        )
        #expect(tokens.contains(CodeToken(kind: .comment, text: "# reverse a string")))
        #expect(tokens.contains(where: { $0.kind == .keyword && $0.text == "def" }))
        #expect(tokens.contains(where: { $0.kind == .keyword && $0.text == "return" }))
        #expect(tokens.contains(where: { $0.kind == .number && $0.text == "1" }))
    }

    @Test("python: a py alias resolves and a triple-quoted string is one token")
    func pythonAliasAndTripleQuote() {
        let tokens = CodeSyntaxHighlighter.tokenize("x = \"\"\"a\nmulti\nline\"\"\"", language: "py")
        #expect(tokens.contains(where: { $0.kind == .string && $0.text.hasPrefix("\"\"\"") }))
    }

    @Test("javascript: // and /* */ comments, and a template-literal backtick string")
    func javascriptBasics() {
        let tokens = CodeSyntaxHighlighter.tokenize(
            "function add(a, b) {\n  // sum\n  return a + b;\n}", language: "js"
        )
        #expect(tokens.contains(where: { $0.kind == .keyword && $0.text == "function" }))
        #expect(tokens.contains(CodeToken(kind: .comment, text: "// sum")))
        let template = CodeSyntaxHighlighter.tokenize("`hello ${name}`", language: "typescript")
        #expect(template.contains(where: { $0.kind == .string && $0.text.hasPrefix("`") }))
    }

    @Test("json: keys and true/false/null are recognized, no type-detection noise")
    func jsonBasics() {
        let tokens = CodeSyntaxHighlighter.tokenize(#"{"a": 1, "b": true}"#, language: "json")
        #expect(tokens.contains(CodeToken(kind: .string, text: "\"a\"")))
        #expect(tokens.contains(where: { $0.kind == .number && $0.text == "1" }))
        #expect(tokens.contains(where: { $0.kind == .keyword && $0.text == "true" }))
        #expect(!tokens.contains { $0.kind == .type })
    }

    @Test("bash: hash comments are recognized and identifiers are never typed")
    func bashBasics() {
        let tokens = CodeSyntaxHighlighter.tokenize("# list files\nls -la $HOME", language: "bash")
        #expect(tokens.contains(CodeToken(kind: .comment, text: "# list files")))
        #expect(!tokens.contains { $0.kind == .type })
    }

    @Test("concatenating every token's text reproduces the original code exactly")
    func tokensReconstructOriginal() {
        let samples: [(code: String, language: String?)] = [
            ("// greet\nfunc greet(name: String) -> String {\n    return \"Hi \\(name)\"\n}", "swift"),
            ("# reverse a string\ndef rev(s):\n    return s[::-1]", "python"),
            ("function add(a, b) {\n  return a + b; // done\n}", "javascript"),
            ("{\"a\": 1}", "json"),
            ("some plain unhighlighted text", nil),
        ]
        for sample in samples {
            let tokens = CodeSyntaxHighlighter.tokenize(sample.code, language: sample.language)
            let reconstructed = tokens.map(\.text).joined()
            #expect(reconstructed == sample.code)
        }
    }
}
