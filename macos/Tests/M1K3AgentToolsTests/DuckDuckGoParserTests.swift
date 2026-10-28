//
//  DuckDuckGoParserTests.swift
//  M1K3AgentToolsTests
//
//  Pure parsers pinned against REAL captured responses (Fixtures/):
//  - ddg-ia-populated.json / ddg-ia-empty.json — api.duckduckgo.com Instant Answer
//  - ddg-lite-results.html — lite.duckduckgo.com result page
//  - ddg-anomaly.html — the bot-challenge page DDG serves when it flags a client
//    (captured live; the parser must return [] for it, never garbage)
//
//  Signed: Kev + claude-fable-5, 2026-06-09, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-opus-5.5, 2026-10-28 — category links are dropped: the captured fixture's 17 related topics
//  hold 11, each only its name, so it now parses to 7 results. Confidence 0.85.

import Foundation
@testable import M1K3AgentTools
import Testing

private func fixture(_ fixtureName: String, extension fileExtension: String) throws -> Data {
    let url = try #require(Bundle.module.url(
        forResource: "Fixtures/\(fixtureName)", withExtension: fileExtension
    ))
    return try Data(contentsOf: url)
}

struct InstantAnswerParserTests {
    @Test("populated response yields the abstract first, then related topics")
    func populatedResponse() throws {
        let results = try DuckDuckGoInstantAnswerParser.parse(
            fixture("ddg-ia-populated", extension: "json")
        )
        let first = try #require(results.first)
        #expect(first.title == "Swift (programming language)")
        #expect(first.url == "https://en.wikipedia.org/wiki/Swift_(programming_language)")
        #expect(first.snippet.hasPrefix("Swift is a high-level general-purpose"))
        // 1 abstract + 17 related topics in the captured fixture, 11 of them category links (bare names).
        #expect(results.count == 7)
        let second = try #require(results.dropFirst().first)
        #expect(second.title == "Objective-C")
        #expect(second.url == "https://duckduckgo.com/Objective-C")
    }

    @Test("empty response yields no results (the HTML-fallback trigger)")
    func emptyResponse() throws {
        let results = try DuckDuckGoInstantAnswerParser.parse(
            fixture("ddg-ia-empty", extension: "json")
        )
        #expect(results.isEmpty)
    }

    @Test("an Answer (calculation/conversion) becomes the first result")
    func answerResponse() {
        let json = """
        {"Answer":"42 (the answer)","AbstractText":"","AbstractURL":"","Heading":"","RelatedTopics":[]}
        """
        let results = DuckDuckGoInstantAnswerParser.parse(Data(json.utf8))
        #expect(results.first?.snippet == "42 (the answer)")
    }

    @Test("nested topic groups are flattened")
    func nestedGroups() {
        let json = """
        {"Answer":"","AbstractText":"","AbstractURL":"","Heading":"","RelatedTopics":[
            {"Name":"Group","Topics":[
                {"Text":"Inner Thing - a nested topic","FirstURL":"https://example.com/inner"}
            ]}
        ]}
        """
        let results = DuckDuckGoInstantAnswerParser.parse(Data(json.utf8))
        #expect(results.count == 1)
        #expect(results.first?.title == "Inner Thing")
        #expect(results.first?.url == "https://example.com/inner")
    }

    /// 2026-10-27 web sample: "Government of Canada — https://duckduckgo.com/c/Government_of_Canada", its
    /// snippet only its name, took a result slot. A topic with something to say stays.
    @Test("a category link carries only its name, so it is dropped")
    func categoryDropped() {
        let json = """
        {"Answer":"","AbstractText":"","AbstractURL":"","Heading":"","RelatedTopics":[
            {"Text":"Spouse of the PM - Diana Fox Carney is his wife.","FirstURL":"https://duckduckgo.com/Spouse"},
            {"Text":"Government of Canada","FirstURL":"https://duckduckgo.com/c/Government_of_Canada"}
        ]}
        """
        let results = DuckDuckGoInstantAnswerParser.parse(Data(json.utf8))
        #expect(results.map(\.title) == ["Spouse of the PM"])
        // Only category links: no results, so the tool falls through to the lite endpoint's real ones.
        let onlyCategories = """
        {"Answer":"","AbstractText":"","AbstractURL":"","Heading":"","RelatedTopics":[
            {"Text":"Government of Canada","FirstURL":"https://duckduckgo.com/c/Government_of_Canada"}
        ]}
        """
        #expect(DuckDuckGoInstantAnswerParser.parse(Data(onlyCategories.utf8)).isEmpty)
    }

    @Test("garbage data yields no results")
    func garbage() {
        #expect(DuckDuckGoInstantAnswerParser.parse(Data("not json".utf8)).isEmpty)
    }
}

struct HTMLParserTests {
    @Test("real lite page yields ranked results with clean text")
    func litePage() throws {
        let html = try #require(try String(
            data: fixture("ddg-lite-results", extension: "html"), encoding: .utf8
        ))
        let results = DuckDuckGoHTMLParser.parse(html: html)
        #expect(results.count == 10)
        let first = try #require(results.first)
        #expect(first.title == "Concurrency - Documentation")
        let expectedURL =
            "https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/"
        #expect(first.url == expectedURL)
        // <b> tags stripped, &#x27; decoded, whitespace collapsed.
        #expect(first.snippet.contains("Swift detects and prevents data races"))
        #expect(first.snippet.contains("can't be detected"))
        #expect(!first.snippet.contains("<"))
    }

    @Test("the real bot-challenge page yields no results, no crash")
    func anomalyPage() throws {
        let html = try #require(try String(
            data: fixture("ddg-anomaly", extension: "html"), encoding: .utf8
        ))
        #expect(DuckDuckGoHTMLParser.parse(html: html).isEmpty)
    }

    @Test("the challenge page is recognised, ordinary pages are not")
    func challengeDetection() throws {
        let challenge = try #require(try String(
            data: fixture("ddg-anomaly", extension: "html"), encoding: .utf8
        ))
        #expect(DuckDuckGoHTMLParser.isChallengePage(challenge))
        let results = try #require(try String(
            data: fixture("ddg-lite-results", extension: "html"), encoding: .utf8
        ))
        #expect(!DuckDuckGoHTMLParser.isChallengePage(results))
        #expect(!DuckDuckGoHTMLParser.isChallengePage("<html>plain empty page</html>"))
    }

    @Test("garbage and empty input yield no results")
    func garbage() {
        #expect(DuckDuckGoHTMLParser.parse(html: "").isEmpty)
        #expect(DuckDuckGoHTMLParser.parse(html: "<html><body>nothing</body>").isEmpty)
        #expect(DuckDuckGoHTMLParser.parse(html: "class='result-link'").isEmpty)
    }

    @Test("uddg redirect links decode to their destination")
    func redirectDecode() {
        let wrapped = "//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpage%3Fa%3D1&rut=abc123"
        #expect(DuckDuckGoHTMLParser.decodeRedirectURL(wrapped) == "https://example.com/page?a=1")
        // Direct links pass through untouched.
        #expect(DuckDuckGoHTMLParser.decodeRedirectURL("https://example.com/x") == "https://example.com/x")
    }

    @Test("plainText strips tags and decodes common entities")
    func plainText() {
        let fragment = "  When you use <b>Swift</b>, races can&#x27;t hide &amp; won&#39;t \n  survive &lt;long&gt;. "
        #expect(DuckDuckGoHTMLParser.plainText(from: fragment)
            == "When you use Swift, races can't hide & won't survive <long>.")
    }
}

struct WebSearchFormatterTests {
    private let results = [
        WebSearchResult(title: "First", url: "https://a.example", snippet: "Snippet one."),
        WebSearchResult(title: "Second", url: "https://b.example", snippet: "Snippet two."),
        WebSearchResult(title: "Third", url: "https://c.example", snippet: "Snippet three."),
    ]

    @Test("numbers results with title, url and snippet, capped at limit")
    func numbersResults() {
        let text = WebSearchFormatter.format(results, limit: 2)
        #expect(text == """
        1. First — https://a.example
           Snippet one.
        2. Second — https://b.example
           Snippet two.
        """)
    }

    @Test("long snippets are truncated so observations stay small-model safe")
    func capsLength() {
        let long = WebSearchResult(
            title: "Long", url: "https://l.example",
            snippet: String(repeating: "word ", count: 200)
        )
        let text = WebSearchFormatter.format([long], limit: 5)
        #expect(text.count < 400)
        #expect(text.contains("…"))
    }
}
