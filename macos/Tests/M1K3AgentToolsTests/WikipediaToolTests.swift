//
//  WikipediaToolTests.swift
//  M1K3AgentToolsTests
//
//  Pins the lookup_fact contract: a hit yields the extract + a Source line; a
//  miss is an honest observation (not an error); a network failure is a
//  recoverable "Error:" (never a throw); the request carries the descriptive
//  Wikimedia User-Agent (NOT the Safari UA); long extracts are capped.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-14, Confidence 0.9, Prior: Unknown
//  Review: Kev + claude-opus-5-5, 2026-10-02 — the UA contact is pinned to the
//  studio address (hello@), never a personal one (#472 follow-up). Confidence 0.95.

import Foundation
@testable import M1K3AgentTools
import Synchronization
import Testing

/// Scripted HTTPFetching fake (local to this suite; the AgentTools fakes are
/// file-private per test file). Always 200 — status handling lives elsewhere.
private final class FakeHTTPFetcher: HTTPFetching, Sendable {
    private let requestLog = Mutex<[URLRequest]>([])
    private let respond: @Sendable (URLRequest) throws -> Data
    private let status: Int

    init(status: Int = 200, respond: @escaping @Sendable (URLRequest) throws -> Data) {
        self.status = status
        self.respond = respond
    }

    var requests: [URLRequest] {
        requestLog.withLock { $0 }
    }

    func fetch(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        requestLog.withLock { $0.append(request) }
        let data = try respond(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return (data, response)
    }
}

private let shannonHit = """
{"batchcomplete":"","query":{"pages":{"12345":{
  "pageid":12345,"ns":0,"title":"Claude Shannon",
  "extract":"Claude Elwood Shannon was an American mathematician and electrical engineer known as the father of information theory.",
  "fullurl":"https://en.wikipedia.org/wiki/Claude_Shannon",
  "canonicalurl":"https://en.wikipedia.org/wiki/Claude_Shannon"
}}}}
"""

private let noMatch = """
{"batchcomplete":"","query":{"searchinfo":{"totalhits":0}}}
"""

struct WikipediaToolTests {
    @Test("a hit returns the extract plus a Source line")
    func lookupHit() async throws {
        let fetcher = FakeHTTPFetcher { _ in Data(shannonHit.utf8) }
        let tool = WikipediaTool(fetcher: fetcher)
        let result = try await tool.execute(input: ["topic": "Claude Shannon"])
        #expect(result.output.contains("father of information theory"))
        #expect(result.output.contains("Source: https://en.wikipedia.org/wiki/Claude_Shannon"))
        #expect(fetcher.requests.count == 1)
        let request = try #require(fetcher.requests.first)
        #expect(request.url?.host == "en.wikipedia.org")
        #expect(request.url?.query?.contains("gsrsearch=Claude%20Shannon") == true)
    }

    @Test("the request carries the descriptive Wikimedia User-Agent, not Safari")
    func descriptiveUserAgent() async throws {
        let fetcher = FakeHTTPFetcher { _ in Data(shannonHit.utf8) }
        let tool = WikipediaTool(fetcher: fetcher)
        _ = try await tool.execute(input: ["topic": "Claude Shannon"])
        let ua = try #require(fetcher.requests.first?.value(forHTTPHeaderField: "User-Agent"))
        #expect(ua.contains("M1K3"))
        // The studio contact, never a person's: the UA goes out to Wikimedia on every lookup.
        #expect(ua.contains("hello@round-tower.ie"))
        #expect(!ua.contains("kevin@"))
        #expect(!ua.contains("Safari"))
    }

    @Test("no article is an honest observation, not an error")
    func noArticle() async throws {
        let fetcher = FakeHTTPFetcher { _ in Data(noMatch.utf8) }
        let tool = WikipediaTool(fetcher: fetcher)
        let result = try await tool.execute(input: ["topic": "asdkfjqwer"])
        #expect(result.output == "No Wikipedia article found for \"asdkfjqwer\".")
    }

    @Test("network failure becomes a recoverable Error observation, not a throw")
    func networkFailure() async throws {
        struct Boom: Error {}
        let fetcher = FakeHTTPFetcher { _ in throw Boom() }
        let tool = WikipediaTool(fetcher: fetcher)
        let result = try await tool.execute(input: ["topic": "anything"])
        #expect(result.output.hasPrefix("Error: Wikipedia lookup failed"))
    }

    @Test("a transient HTTP status is reported as temporarily unavailable, not a miss")
    func transientStatus() async throws {
        // 503 with a non-match body would otherwise parse to nil → "no article".
        let fetcher = FakeHTTPFetcher(status: 503) { _ in Data(noMatch.utf8) }
        let tool = WikipediaTool(fetcher: fetcher)
        let result = try await tool.execute(input: ["topic": "anything"])
        #expect(result.output.contains("temporarily unavailable"))
    }

    @Test("empty topic is rejected without any request")
    func emptyTopic() async throws {
        let fetcher = FakeHTTPFetcher { _ in Data() }
        let tool = WikipediaTool(fetcher: fetcher)
        let result = try await tool.execute(input: ["topic": "   "])
        #expect(result.output == "Error: empty topic.")
        #expect(fetcher.requests.isEmpty)
    }

    @Test("declares the agent-facing contract")
    func declaresContract() {
        let tool = WikipediaTool()
        #expect(tool.name == "lookup_fact")
        #expect(tool.description.contains("Wikipedia"))
        #expect(tool.parameters.first?.name == "topic")
    }
}

struct WikipediaSummaryParserTests {
    @Test("lifts title, extract, and url from a query response")
    func parsesHit() {
        let fact = try? #require(WikipediaSummaryParser.parse(Data(shannonHit.utf8)))
        #expect(fact?.title == "Claude Shannon")
        #expect(fact?.extract.contains("father of information theory") == true)
        #expect(fact?.url == "https://en.wikipedia.org/wiki/Claude_Shannon")
    }

    @Test("returns nil when the search found nothing")
    func parsesMiss() {
        #expect(WikipediaSummaryParser.parse(Data(noMatch.utf8)) == nil)
        #expect(WikipediaSummaryParser.parse(Data("{}".utf8)) == nil)
        #expect(WikipediaSummaryParser.parse(Data("not json".utf8)) == nil)
    }

    @Test("falls back to a constructed URL when info URLs are absent")
    func constructsURL() {
        let json = """
        {"query":{"pages":{"7":{"title":"Round tower","extract":"A round tower is a stone tower."}}}}
        """
        let fact = WikipediaSummaryParser.parse(Data(json.utf8))
        #expect(fact?.url == "https://en.wikipedia.org/wiki/Round_tower")
    }

    @Test("a page with no extract is treated as no article")
    func emptyExtractIsNil() {
        let json = """
        {"query":{"pages":{"7":{"title":"Stub","extract":"   ","fullurl":"https://en.wikipedia.org/wiki/Stub"}}}}
        """
        #expect(WikipediaSummaryParser.parse(Data(json.utf8)) == nil)
    }
}

struct WikipediaFormatterTests {
    @Test("caps a long extract and keeps the Source line")
    func capsLongExtract() {
        let long = String(repeating: "a", count: 2000)
        let fact = WikipediaFact(title: "T", extract: long, url: "https://en.wikipedia.org/wiki/T")
        let output = WikipediaFormatter.format(fact)
        #expect(output.contains("…"))
        #expect(output.contains("Source: https://en.wikipedia.org/wiki/T"))
        // extract portion capped (well under the raw 2000)
        #expect(output.count < 1400)
    }
}
