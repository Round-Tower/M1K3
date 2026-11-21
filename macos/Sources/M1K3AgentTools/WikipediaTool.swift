//
//  WikipediaTool.swift
//  M1K3AgentTools
//
//  A keyless, CITED answer engine for established facts. One MediaWiki call
//  searches + returns the intro extract together; the model gets prose plus a
//  Source URL, so factual questions resolve to a verifiable summary instead of
//  a confabulation. Scoped in the description AWAY from current events / prices /
//  weather — those still belong to web_search.
//
//  Privacy: the topic leaves the device (to en.wikipedia.org) — injected only
//  when the user's web-search setting is on, exactly like web_search/fetch_page.
//  Wikimedia's API policy asks for a descriptive User-Agent with contact info;
//  we send one (NOT the Safari UA the scrape tools use). Errors are returned as
//  observations, never thrown.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-14, Confidence 0.9, Prior: Unknown
//  Review: Kev + claude-opus-5-5, 2026-10-02 — Wikimedia UA contact → hello@round-tower.ie
//  (the studio address; #472 moved every other public surface). Pinned by WikipediaToolTests.
//  Confidence 0.95.
//  Review: claude-opus-5-5, 2026-11-20 — a status that is neither OK nor transient (a 403 from the UA policy, a 404,
//  a 5xx) is logged at notice before it reads as "no article": the only line was a .debug, which never persists.
//  Logging only. Confidence 0.85.
//  Review: claude-opus-5-5, 2026-11-21 (pre-push review fold) — the topic is hashed in every log line, and a lookup error logs
//  domain and code only (a URLError's description carries the URL). Confidence 0.85.

import Foundation
import M1K3Agent
import M1K3LogCore
import os

public struct WikipediaTool: AgentTool {
    private static let log = Logger(subsystem: M1K3Log.subsystem, category: "wikipedia")
    public let name = "lookup_fact"
    /// P1 same-turn exclusion (context-tools charter): this tool reaches the
    /// network, so it never runs in the same turn as a local-sensitive tool.
    public let exclusionClass: ToolExclusionClass? = .network
    public let description =
        "Look up an established fact from Wikipedia — people, places, concepts, history, "
            + "definitions. NOT for current events, prices, or weather (use web_search for those). "
            + "Argument: the topic, e.g. 'Claude Shannon'. Returns a short encyclopedic summary with a source link."
    public let parameters = [
        ToolParameter(name: "topic", description: "the person, place, or concept to look up"),
    ]

    /// Wikimedia API etiquette: identify the app + a contact, per their UA policy.
    static let wikipediaUserAgent = "M1K3/1.0 (https://m1k3.app; hello@round-tower.ie)"

    private let fetcher: any HTTPFetching

    public init(fetcher: any HTTPFetching = RetryingHTTPFetcher.production) {
        self.fetcher = fetcher
    }

    public func execute(input: [String: String]) async throws -> ToolResult {
        let topic = (input["topic"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else {
            return ToolResult(output: "Error: empty topic.")
        }
        do {
            let (data, response) = try await fetch(queryURL(for: topic))
            Self.log.debug("HTTP \(response.statusCode) for \"\(topic, privacy: .private(mask: .hash))\"")
            // Distinguish a throttle/outage (after the fetcher's retry) from a
            // genuine miss — else the model is told "no such article" wrongly.
            if HTTPStatus.classify(response.statusCode) == .transient {
                Self.log.notice("transient HTTP \(response.statusCode) for \"\(topic, privacy: .private(mask: .hash))\"")
                return ToolResult(output: "Error: Wikipedia is temporarily unavailable. "
                    + "Answer from what you already have, with appropriate uncertainty.")
            }
            let status = response.statusCode
            if HTTPStatus.classify(status) != .ok {
                // Not an article lookup: without this line a refused lookup reads as "no such article".
                Self.log.notice("HTTP \(status, privacy: .public) on a lookup: read as no article")
            }
            guard let fact = WikipediaSummaryParser.parse(data) else {
                Self.log.info("no article for \"\(topic, privacy: .private(mask: .hash))\"")
                // Wording is load-bearing: ToolDispatch.emptyResultPrefixes reads it (ADR 0009).
                return ToolResult(output: "No Wikipedia article found for \"\(topic)\".")
            }
            return ToolResult(output: WikipediaFormatter.format(fact))
        } catch {
            let reason = ErrorChain.summary(error)
            Self.log.error("lookup failed for \"\(topic, privacy: .private(mask: .hash))\": \(reason, privacy: .public)")
            return ToolResult(output: "Error: Wikipedia lookup failed — \(error.localizedDescription)")
        }
    }

    private func fetch(_ url: URL) async throws -> (data: Data, response: HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue(Self.wikipediaUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try await fetcher.fetch(request)
    }

    /// One call: search for the topic and pull the best page's intro extract +
    /// canonical URL together (generator=search feeding prop=extracts|info).
    private func queryURL(for topic: String) -> URL {
        var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "prop", value: "extracts|info"),
            URLQueryItem(name: "inprop", value: "url"),
            URLQueryItem(name: "exintro", value: "1"),
            URLQueryItem(name: "explaintext", value: "1"),
            URLQueryItem(name: "redirects", value: "1"),
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: topic),
            URLQueryItem(name: "gsrlimit", value: "1"),
        ]
        return components.url!
    }
}
