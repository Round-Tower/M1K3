//
//  ArtifactOpenPolicyTests.swift
//  M1K3PreviewTests
//
//  Signed: Kev + claude-opus-5-5, 2026-11-23, Confidence 0.85, Prior: Unknown (new file)

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

    // MARK: - Where it shows

    @Test("regular width shows beside the chat, compact is a sheet")
    func presentation() {
        #expect(ArtifactPresentation.style(isRegularWidth: true) == .besideChat)
        #expect(ArtifactPresentation.style(isRegularWidth: false) == .sheet)
    }
}
