//
//  OpenLinkTool.swift
//  M1K3AgentTools
//
//  Lets M1K3's local agent surface a web link into the review panel mid-answer —
//  "here, take a look at this" — instead of only describing it. The tool owns no
//  UI: it validates the URL through the shared ReviewTargetResolver (web only —
//  the agent shouldn't open arbitrary local files) and hands it to an injected
//  callback the app routes to the ReviewModel.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-19, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-09-04 — the tool now READS what it opens:
//  after the panel gets the URL it fetches the page + the origin's llms.txt
//  (tight 8s fetcher, same guards as fetch_page) and returns a PageBrief instead
//  of a bare "Opened host". The bare line left the model holding nothing and
//  it narrated a page it never saw (Kev's dislike, 2026-09-04).

import Foundation
import M1K3Agent
import M1K3Preview

public struct OpenLinkTool: AgentTool {
    public let name = "open_link"
    /// P1 same-turn exclusion (context-tools charter): this tool reaches the
    /// network, so it never runs in the same turn as a local-sensitive tool.
    public let exclusionClass: ToolExclusionClass? = .network
    public let description =
        "Open a web link in M1K3's review panel beside the conversation, so the user "
            + "can see the page without leaving M1K3 — and get back a short brief of what the page is "
            + "(title, description, the site's note for AI agents, a first chunk of its text). "
            + "Use when you reference a URL worth looking at, or when the user asks you to open a site. "
            + "To READ a page in full, use fetch_page. Argument: the http(s) link to open."
    public let parameters = [
        ToolParameter(name: "url", description: "the http(s) link to open"),
    ]

    private let onOpen: @Sendable (URL) -> Void
    private let fetcher: any HTTPFetching

    /// The brief's reader is the tight no-retry fetch web_search's deepen uses:
    /// a slow or JS-only page bails fast; the panel has already opened either way.
    public init(
        fetcher: any HTTPFetching = URLSessionHTTPFetcher(timeout: 8),
        onOpen: @escaping @Sendable (URL) -> Void
    ) {
        self.fetcher = fetcher
        self.onOpen = onOpen
    }

    public func execute(input: [String: String]) async throws -> ToolResult {
        let raw = (input["url"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            return ToolResult(output: "Error: no URL given.")
        }
        // Web only — a clicked-open file would need a sandbox grant the agent
        // doesn't have, and "open a link" means a page, not a path.
        guard case let .web(url) = ReviewTargetResolver.resolve(raw) else {
            return ToolResult(output: "Error: \"\(raw)\" isn't a web link M1K3 can open.")
        }
        // Public web only — the embedded WebView fetches from the user's Mac, so
        // an agent must not aim it at localhost / the LAN / cloud-metadata.
        guard !WebURLPolicy.isLocalOrPrivate(url) else {
            return ToolResult(output: "Error: M1K3 won't open local or private-network addresses (\(url.host ?? raw)).")
        }
        // Open FIRST — the user sees the page even if the read below fails.
        onOpen(url)
        let sources = await Self.gather(url: url, fetcher: fetcher)
        return ToolResult(output: PageBrief.render(url: url, sources: sources))
    }

    /// The page (browser-headed, the same request fetch_page sends) and the
    /// origin's llms.txt. Never throws: a failed page read becomes the brief's
    /// explicit failure; a missing llms.txt is simply absent.
    static func gather(url: URL, fetcher: any HTTPFetching) async -> PageBriefSources {
        var sources = PageBriefSources()
        do {
            let (data, response) = try await fetcher.fetch(FetchPageTool.pageRequest(for: url))
            if HTTPStatus.classify(response.statusCode) == .ok {
                sources.html = BodyDecoder.decode(
                    data, contentType: response.value(forHTTPHeaderField: "Content-Type")
                )
            } else {
                sources.failure = "HTTP \(response.statusCode)"
            }
        } catch {
            sources.failure = "fetch failed: \(error.localizedDescription)"
        }
        if let llmsURL = PageBrief.llmsURL(for: url) {
            var request = FetchPageTool.pageRequest(for: llmsURL)
            request.setValue("text/plain, text/markdown;q=0.9, */*;q=0.1", forHTTPHeaderField: "Accept")
            if let (data, response) = try? await fetcher.fetch(request),
               HTTPStatus.classify(response.statusCode) == .ok
            {
                sources.llmsText = PageBrief.usableLLMSText(
                    BodyDecoder.decode(data, contentType: response.value(forHTTPHeaderField: "Content-Type"))
                )
            }
        }
        return sources
    }
}
