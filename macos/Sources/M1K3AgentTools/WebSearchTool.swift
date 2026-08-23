//
//  WebSearchTool.swift
//  M1K3AgentTools
//
//  DuckDuckGo web search behind the AgentTool seam. Instant Answer API first
//  (clean JSON, but empty for most natural queries), then the lite HTML
//  endpoint as the real workhorse. Chosen empirically 2026-06-09: the classic
//  html.duckduckgo.com GET serves a bot-challenge ("anomaly") page to
//  non-browser clients, while lite.duckduckgo.com returns results with
//  DIRECT hrefs. If lite gets flagged too, the parser sees no result markers
//  and we answer honestly with "No web results".
//
//  Privacy: the query leaves the device (to DuckDuckGo) — the app only
//  injects this tool when the user's web-search setting is on, and the chat
//  UI surfaces every search visibly. Errors are returned as observations,
//  never thrown, so the agent loop can recover and conclude from what it has.
//
//  Signed: Kev + claude-fable-5, 2026-06-09, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-opus-4-8, 2026-06-30, Confidence 0.9 — deterministic
//  deepen: small models won't chain to fetch_page on their own, so web_search
//  now concurrently reads the top-2 results (tight no-retry timeout via an
//  injected deepReader) and appends the first readable page's text, degrading
//  to snippets when nothing reads. The link list was never the answer.

import Foundation
import M1K3Agent
import M1K3Inference
import os

public struct WebSearchTool: AgentTool {
    private static let log = Logger(subsystem: M1K3Log.subsystem, category: "web-search")
    public let name = "web_search"
    /// P1 same-turn exclusion (context-tools charter): this tool reaches the
    /// network, so it never runs in the same turn as a local-sensitive tool.
    public let exclusionClass: ToolExclusionClass? = .network
    public let description =
        "Search the web via DuckDuckGo for current or external information "
            + "(news, facts, anything not in stored knowledge). Argument: the search query."
    public let parameters = [
        ToolParameter(name: "query", description: "the web search query"),
    ]

    static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    private let fetcher: any HTTPFetching
    private let maxResults: Int
    private let deepReader: FetchPageTool?

    public init(
        fetcher: any HTTPFetching = RetryingHTTPFetcher.production,
        maxResults: Int = 5,
        deepReader: FetchPageTool? = nil
    ) {
        self.fetcher = fetcher
        self.maxResults = maxResults
        self.deepReader = deepReader
    }

    public func execute(input: [String: String]) async throws -> ToolResult {
        let query = (input["query"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return ToolResult(output: "Error: empty query.")
        }
        do {
            switch try await search(query: query) {
            case .rateLimited:
                Self.log.notice("rate-limited: DDG served the challenge page for \"\(query, privacy: .public)\"")
                return ToolResult(output: "Error: web search is temporarily unavailable "
                    + "(DuckDuckGo rate-limited \(HostPlatform.thisDevice)). Answer from what you already have.")
            case let .results(results) where results.isEmpty:
                // .notice: "the search found nothing" is a load-bearing breadcrumb
                // (distinguishes empty-result from never-ran) that must persist.
                Self.log.notice("no results for \"\(query, privacy: .public)\"")
                return ToolResult(output: "No web results for \"\(query)\".")
            case let .results(results):
                Self.log.notice("\(results.count) result(s) for \"\(query, privacy: .public)\"")
                let base = WebSearchFormatter.format(results, limit: maxResults)
                return ToolResult(output: await deepened(base, results: results))
            }
        } catch {
            Self.log.error("fetch failed for \"\(query, privacy: .public)\": \(error, privacy: .public)")
            return ToolResult(output: "Error: web search failed — \(error.localizedDescription)")
        }
    }

    /// Deterministic search→read chain: small models won't call fetch_page on
    /// their own (seen live — gemma searches, then concludes with filler), so
    /// when a deep reader is wired we fetch the top result's text and append it
    /// to the SAME observation the model reliably triggers. Tries the first two
    /// results (the top hit is often a JS aggregator with no static text) and
    /// degrades to snippets-only when nothing is readable.
    private func deepened(_ base: String, results: [WebSearchResult]) async -> String {
        guard let deepReader else { return base }
        let candidates = Array(results.prefix(2))
        guard !candidates.isEmpty else { return base }
        // Read the top candidates CONCURRENTLY (so total latency is one fetch, not
        // the sum) and take the highest-ranked one that yields text. The deep
        // reader carries a tight, no-retry timeout — a slow/JS page bails fast
        // rather than blowing the turn's budget.
        let contents = await withTaskGroup(of: (Int, String?).self) { group in
            for (index, result) in candidates.enumerated() {
                group.addTask { (index, await deepReader.readablePage(at: result.url)) }
            }
            var byIndex: [Int: String] = [:]
            for await (index, content) in group {
                if let content { byIndex[index] = content }
            }
            return byIndex
        }
        for (index, result) in candidates.enumerated() {
            if let content = contents[index] {
                return base + "\n\nPage content from \(result.url):\n\(content)"
            }
        }
        return base
    }

    private enum SearchOutcome {
        case results([WebSearchResult])
        /// DDG served its bot-challenge page — rate-limited, not "no results".
        case rateLimited
    }

    private func search(query: String) async throws -> SearchOutcome {
        let instantResponse = try await fetch(instantAnswerURL(for: query))
        let instant = DuckDuckGoInstantAnswerParser.parse(instantResponse.data)
        Self.log.debug("""
        instant answer: HTTP \(instantResponse.response.statusCode) → \(instant.count) result(s) \
        for "\(query, privacy: .public)"
        """)
        if !instant.isEmpty { return .results(instant) }

        let fallback = try await fetch(liteURL(for: query))
        // A throttle status (202/429/503) is a rate-limit even when the body
        // carries no challenge markers — don't depend on the HTML string-match alone.
        if HTTPStatus.classify(fallback.response.statusCode) == .transient {
            return .rateLimited
        }
        let html = BodyDecoder.decode(
            fallback.data, contentType: fallback.response.value(forHTTPHeaderField: "Content-Type")
        )
        let results = DuckDuckGoHTMLParser.parse(html: html)
        Self.log.debug("""
        lite fallback: HTTP \(fallback.response.statusCode), \(html.count) bytes → \
        \(results.count) result(s), challenge=\(DuckDuckGoHTMLParser.isChallengePage(html))
        """)
        if results.isEmpty, DuckDuckGoHTMLParser.isChallengePage(html) {
            return .rateLimited
        }
        return .results(results)
    }

    private func fetch(_ url: URL) async throws -> (data: Data, response: HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/json", forHTTPHeaderField: "Accept")
        request.setValue("en-GB,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        return try await fetcher.fetch(request)
    }

    private func instantAnswerURL(for query: String) -> URL {
        var components = URLComponents(string: "https://api.duckduckgo.com/")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "no_html", value: "1"),
            URLQueryItem(name: "skip_disambig", value: "1"),
        ]
        return components.url!
    }

    private func liteURL(for query: String) -> URL {
        var components = URLComponents(string: "https://lite.duckduckgo.com/lite/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url!
    }
}
