//
//  OpenLinkRoutingTests.swift
//  M1K3ChatTests
//
//  Pins the open_link routing line (show vs read) as offered-only. Added with
//  #207 (the page brief); header added with #208 — the file shipped unsigned.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-04, Confidence 0.9, Prior: Unknown

import Foundation
@testable import M1K3Chat
import Testing

/// The routing line that stops the model narrating a page it never read. Only
/// present when open_link is actually offered — every routing line names
/// callable tools only (the doomed-dispatch rule).
struct OpenLinkRoutingTests {
    private let webTools: Set<String> = ["web_search", "search_knowledge", "fetch_page"]

    @Test("with open_link offered, the rules say: show vs read, and describe only what a tool returned")
    func lineWhenOffered() {
        for style in [AgentRAGResponder.PromptStyle.react, .native] {
            let prompt = AgentRAGResponder.grounding(
                chunks: [], toolNames: webTools.union(["open_link"]), style: style
            )
            #expect(prompt.contains(AgentRAGResponder.openLinkRouting))
            #expect(prompt.contains("Describe a page only from what a tool returned"))
        }
    }

    @Test("without open_link, the line is absent")
    func absentWhenNotOffered() {
        let prompt = AgentRAGResponder.grounding(chunks: [], toolNames: webTools, style: .react)
        #expect(!prompt.contains("open_link"))
    }
}
