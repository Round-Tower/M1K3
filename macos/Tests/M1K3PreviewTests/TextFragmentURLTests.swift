//
//  TextFragmentURLTests.swift
//  M1K3PreviewTests
//
//  The `#:~:text=` builder behind "show me what Mike is quoting" (#839): escaping per the WICG
//  Text Fragments spec, the long-quote `start,end` form, and the refusals.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-15, Confidence 0.85. Prior: none (new file).

import Foundation
@testable import M1K3Preview
import Testing

struct TextFragmentURLTests {
    private func url(_ string: String) throws -> URL {
        try #require(URL(string: string))
    }

    private func fragment(of result: URL?) -> String? {
        guard let result else { return nil }
        return URLComponents(url: result, resolvingAgainstBaseURL: false)?.percentEncodedFragment
    }

    @Test("a plain quote becomes a text directive, spaces escaped")
    func plainQuote() throws {
        let built = try TextFragmentURL.url(for: url("https://example.com/a"), quote: "the quick brown fox")
        #expect(fragment(of: built) == ":~:text=the%20quick%20brown%20fox")
        #expect(built?.host == "example.com")
        #expect(built?.path == "/a")
    }

    @Test("the spec's three delimiters are escaped: dash, ampersand and comma")
    func delimitersEscaped() throws {
        let built = try TextFragmentURL.url(for: url("https://example.com"), quote: "a-b & c, d")
        #expect(fragment(of: built) == ":~:text=a%2Db%20%26%20c%2C%20d")
    }

    @Test("other reserved and non-ASCII characters are percent-encoded as UTF-8")
    func otherCharacters() throws {
        let built = try TextFragmentURL.url(for: url("https://example.com"), quote: "50% of café?")
        #expect(fragment(of: built) == ":~:text=50%25%20of%20caf%C3%A9%3F")
    }

    @Test("runs of whitespace and newlines collapse to one space")
    func whitespaceCollapses() throws {
        let built = try TextFragmentURL.url(for: url("https://example.com"), quote: "  one\n\ttwo   three ")
        #expect(fragment(of: built) == ":~:text=one%20two%20three")
    }

    @Test("an empty or whitespace-only quote gives the URL back unchanged", arguments: ["", "   ", "\n\t "])
    func emptyQuote(quote: String) throws {
        let original = try url("https://example.com/page?x=1")
        #expect(TextFragmentURL.url(for: original, quote: quote) == original)
        #expect(TextFragmentURL.url(for: original, quote: nil) == original)
    }

    @Test("an existing fragment is replaced, not appended to")
    func replacesFragment() throws {
        let built = try TextFragmentURL.url(for: url("https://example.com/p#section-2"), quote: "hello world")
        #expect(fragment(of: built) == ":~:text=hello%20world")
        let again = try TextFragmentURL.url(for: url("https://example.com/p#:~:text=old"), quote: "new words")
        #expect(fragment(of: again) == ":~:text=new%20words")
    }

    @Test("the query string survives")
    func keepsQuery() throws {
        let built = try TextFragmentURL.url(for: url("https://example.com/p?id=7&q=a"), quote: "found it")
        #expect(try URLComponents(url: #require(built), resolvingAgainstBaseURL: false)?.query == "id=7&q=a")
    }

    @Test("a quote past the limit becomes start,end with the edges kept")
    func longQuoteUsesRange() throws {
        let words = (1 ... 120).map { "word\($0)" }
        let quote = words.joined(separator: " ")
        #expect(quote.count > TextFragmentURL.maxExactLength)
        let built = try TextFragmentURL.url(for: url("https://example.com"), quote: quote)
        let value = try #require(fragment(of: built))
        let body = try #require(value.split(separator: "=", maxSplits: 1).last)
        let parts = body.split(separator: ",", omittingEmptySubsequences: false)
        #expect(parts.count == 2)
        #expect(parts[0] == "word1%20word2%20word3%20word4")
        #expect(parts[1] == "word117%20word118%20word119%20word120")
    }

    @Test("a quote exactly at the limit stays exact")
    func atLimitStaysExact() throws {
        let quote = String(repeating: "a", count: TextFragmentURL.maxExactLength)
        let built = try TextFragmentURL.url(for: url("https://example.com"), quote: quote)
        #expect(fragment(of: built) == ":~:text=" + quote)
    }

    @Test("one huge unbroken token is cut rather than sent whole")
    func hugeToken() throws {
        let quote = String(repeating: "x", count: 5000)
        let built = try TextFragmentURL.url(for: url("https://example.com"), quote: quote)
        let value = try #require(fragment(of: built))
        #expect(value.count <= TextFragmentURL.maxExactLength + ":~:text=".count)
    }

    @Test("a non-http(s) URL is refused", arguments: [
        "file:///etc/hosts", "javascript:alert(1)", "ftp://example.com/x", "m1k3://event/x", "data:text/html,hi",
    ])
    func refusesOtherSchemes(raw: String) throws {
        #expect(try TextFragmentURL.url(for: url(raw), quote: "anything at all") == nil)
        // Even with nothing to highlight, a non-web URL is not handed back as openable.
        #expect(try TextFragmentURL.url(for: url(raw), quote: nil) == nil)
    }

    @Test("scheme case does not matter")
    func schemeCase() throws {
        #expect(try TextFragmentURL.url(for: url("HTTPS://example.com"), quote: "some words") != nil)
    }
}
