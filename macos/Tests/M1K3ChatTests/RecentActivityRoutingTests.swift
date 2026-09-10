//
//  RecentActivityRoutingTests.swift
//  M1K3ChatTests
//
//  Pins the recent_activity routing line on the ASSEMBLED prompt: a question
//  about what happened lately on this Mac is a tool call, never a
//  reconstruction from the history window — and the line is offered-only.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-10, Confidence 0.9, Prior: none (new file).
//

import Foundation
@testable import M1K3Chat
import Testing

struct RecentActivityRoutingTests {
    @Test("with recent_activity offered, the rule routes 'what happened lately' to the tool")
    func lineWhenOffered() {
        for style in [AgentRAGResponder.PromptStyle.react, .native] {
            let prompt = AgentRAGResponder.grounding(
                chunks: [], toolNames: ["search_knowledge", "recent_activity"], style: style
            )
            #expect(prompt.contains(AgentRAGResponder.recentActivityRouting))
            #expect(prompt.contains("call recent_activity"))
        }
    }

    @Test("without recent_activity, no rule names it")
    func absentWhenNotOffered() {
        let prompt = AgentRAGResponder.grounding(
            chunks: [], toolNames: ["search_knowledge", "web_search"], style: .react
        )
        #expect(!prompt.contains("recent_activity"))
    }
}
