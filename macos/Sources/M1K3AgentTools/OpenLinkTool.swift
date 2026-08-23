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
            + "can see the page without leaving M1K3. Use when you reference a URL worth looking at. "
            + "Argument: the http(s) link to open."
    public let parameters = [
        ToolParameter(name: "url", description: "the http(s) link to open"),
    ]

    private let onOpen: @Sendable (URL) -> Void

    public init(onOpen: @escaping @Sendable (URL) -> Void) {
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
        onOpen(url)
        return ToolResult(output: "Opened \(url.host ?? url.absoluteString) in the review panel.")
    }
}
