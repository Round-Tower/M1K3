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

import Foundation
import M1K3Agent
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
    static let wikipediaUserAgent = "M1K3/1.0 (https://m1k3.app; kevin@round-tower.ie)"

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
            Self.log.debug("HTTP \(response.statusCode) for \"\(topic, privacy: .public)\"")
            // Distinguish a throttle/outage (after the fetcher's retry) from a
            // genuine miss — else the model is told "no such article" wrongly.
            if HTTPStatus.classify(response.statusCode) == .transient {
                Self.log.notice("transient HTTP \(response.statusCode) for \"\(topic, privacy: .public)\"")
                return ToolResult(output: "Error: Wikipedia is temporarily unavailable. "
                    + "Answer from what you already have, with appropriate uncertainty.")
            }
            guard let fact = WikipediaSummaryParser.parse(data) else {
                Self.log.info("no article for \"\(topic, privacy: .public)\"")
                return ToolResult(output: "No Wikipedia article found for \"\(topic)\".")
            }
            return ToolResult(output: WikipediaFormatter.format(fact))
        } catch {
            Self.log.error("lookup failed for \"\(topic, privacy: .public)\": \(error, privacy: .public)")
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
