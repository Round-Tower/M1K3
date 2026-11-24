//
//  ArtifactOpenPolicyTests.swift
//  M1K3PreviewTests
//
//  Signed: Kev + claude-opus-5-5, 2026-11-23, Confidence 0.85, Prior: Unknown (new file)

import Foundation
@testable import M1K3Preview
import Testing

struct ArtifactOpenPolicyTests {
    // MARK: - The Open button (one block, the one that was tapped)

    @Test("an html block opens as html, rendered")
    func htmlBlock() {
        let artifact = ArtifactOpenPolicy.artifact(language: "html", code: "<h1>Hi</h1>")
        #expect(artifact?.language == .html)
        #expect(artifact?.source == "<h1>Hi</h1>")
        #expect(artifact?.language.isRenderable == true)
    }

    @Test("a named language opens as generic code carrying its label")
    func namedLanguage() {
        let artifact = ArtifactOpenPolicy.artifact(language: "python", code: "print(1)")
        #expect(artifact?.language == .code)
        #expect(artifact?.languageLabel == "python")
    }

    @Test("an untagged block is sniffed: a full page is html")
    func untaggedHTML() {
        let artifact = ArtifactOpenPolicy.artifact(language: nil, code: "<!DOCTYPE html><html><body>x</body></html>")
        #expect(artifact?.language == .html)
    }

    @Test("an untagged block that is not recognisably anything still opens as code")
    func untaggedUnknown() {
        let artifact = ArtifactOpenPolicy.artifact(language: "", code: "just some text")
        #expect(artifact?.language == .code)
        #expect(artifact?.languageLabel == nil)
    }

    @Test("the tag is case-insensitive and trimmed")
    func tagNormalised() {
        #expect(ArtifactOpenPolicy.artifact(language: " HTML ", code: "<p>x</p>")?.language == .html)
        #expect(ArtifactOpenPolicy.artifact(language: "CSS", code: "a{color:red}")?.language == .css)
    }

    @Test("an empty block opens nothing")
    func emptyBlock() {
        #expect(ArtifactOpenPolicy.artifact(language: "html", code: "  \n") == nil)
    }

    // MARK: - Auto-open (an answer landed, from any route)

    @Test("auto-open picks the HTML block even when code comes first")
    func autoOpenPrefersRenderable() {
        let artifacts = CodeBlockDetector.detect(in: """
        ```python
        print(1)
        ```
        ```html
        <h1>Page</h1>
        ```
        """)
        #expect(ArtifactOpenPolicy.autoOpen(from: artifacts)?.language == .html)
    }

    @Test("auto-open leaves plain code to its Open button")
    func autoOpenIgnoresPlainCode() {
        let artifacts = CodeBlockDetector.detect(in: "```swift\nlet x = 1\n```")
        #expect(artifacts.count == 1)
        #expect(ArtifactOpenPolicy.autoOpen(from: artifacts) == nil)
    }

    @Test("auto-open keeps the tagged <artifact> document behaviour")
    func autoOpenTaggedDocument() {
        let artifacts = CodeBlockDetector.detect(in: "<artifact title=\"Plan\">\n# Plan\n</artifact>")
        #expect(ArtifactOpenPolicy.autoOpen(from: artifacts)?.title == "Plan")
    }

    @Test("an answer's text opens its page: a small web page in prose and a fence")
    func autoOpenInAnswer() {
        let text = "Here you go:\n```html\n<!DOCTYPE html><html><body><h1>Hi</h1></body></html>\n```\nEnjoy."
        #expect(ArtifactOpenPolicy.autoOpen(inAnswer: text)?.language == .html)
        #expect(ArtifactOpenPolicy.autoOpen(inAnswer: "No code here.") == nil)
    }

    @Test("auto-open on nothing is nothing")
    func autoOpenEmpty() {
        #expect(ArtifactOpenPolicy.autoOpen(from: []) == nil)
    }

    // MARK: - A page shared in (#893 C meets B)

    @Test("a shared .html file opens as its page, titled by its name, so sharing it back keeps the name")
    func sharedHTMLOpens() throws {
        let page = try #require(ArtifactOpenPolicy.sharedPage(filename: "Solar System.html", text: "<h1>Sun</h1>"))
        #expect(page.language == .html)
        #expect(page.title == "Solar System")
        #expect(page.filename == "Solar System.html")
        #expect(page.source.contains("<h1>") && page.source.contains("Sun"), "the formatter may re-indent, never drop")
    }

    @Test("a shared markdown file opens with a rendered preview; .htm and upper case count")
    func sharedMarkdownAndVariants() throws {
        let notes = try #require(ArtifactOpenPolicy.sharedPage(filename: "notes.md", text: "# Hi"))
        #expect(notes.language == .markdown && notes.previewSource != nil)
        #expect(ArtifactOpenPolicy.sharedPage(filename: "OLD.HTM", text: "<p>x</p>")?.language == .html)
    }

    @Test("code, data and blank files stay in the composer only: nothing to look at")
    func sharedNonPagesStayPut() {
        #expect(ArtifactOpenPolicy.sharedPage(filename: "data.json", text: "{}") == nil)
        #expect(ArtifactOpenPolicy.sharedPage(filename: "main.swift", text: "let x = 1") == nil)
        #expect(ArtifactOpenPolicy.sharedPage(filename: "style.css", text: "a { color: red }") == nil)
        #expect(ArtifactOpenPolicy.sharedPage(filename: "empty.html", text: "  \n") == nil)
        #expect(ArtifactOpenPolicy.sharedPage(filename: "noext", text: "<p>x</p>") == nil)
    }

    @Test("the Code tab highlights as the artifact's own language")
    func highlightLanguage() {
        #expect(CodeArtifact(source: "x", language: .html).highlightLanguage == "html")
        #expect(CodeArtifact(source: "x", language: .css).highlightLanguage == "css")
        #expect(CodeArtifact(source: "x", language: .code, languageLabel: "swift").highlightLanguage == "swift")
        #expect(CodeArtifact(source: "x", language: .markdown).highlightLanguage == nil)
        #expect(CodeArtifact(source: "x", language: .code).highlightLanguage == nil)
    }

    // MARK: - Where it shows

    @Test("a wide regular window shows beside the chat; compact or narrow is a sheet")
    func presentation() {
        #expect(ArtifactPresentation.style(isRegularWidth: true, width: 1024) == .besideChat)
        #expect(ArtifactPresentation.style(isRegularWidth: true, width: 900) == .besideChat)
        // Half-width Split View is still regular, but too narrow to share.
        #expect(ArtifactPresentation.style(isRegularWidth: true, width: 507) == .sheet)
        #expect(ArtifactPresentation.style(isRegularWidth: false, width: 1200) == .sheet)
    }

    @Test("an artifact shows only in the conversation it was opened in")
    func scoped() {
        let here = UUID()
        let scoped = ScopedArtifact(CodeArtifact(source: "<p>x</p>", language: .html), conversationID: here)
        #expect(scoped.visible(in: here)?.source == "<p>x</p>")
        #expect(scoped.visible(in: UUID()) == nil)
    }

    @Test("formatting keeps createdAt, so a sheet/column identity stays stable")
    func formatKeepsIdentity() {
        let artifact = CodeArtifact(source: "<p>x</p>", language: .html)
        #expect(ArtifactFormatter.format(artifact).createdAt == artifact.createdAt)
    }
}
