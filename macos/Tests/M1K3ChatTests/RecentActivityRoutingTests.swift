//
//  RecentActivityRoutingTests.swift
//  M1K3ChatTests
//
//  Pins the recent_activity routing line on the ASSEMBLED prompt: a question
//  about what happened lately on this Mac is a tool call, never a
//  reconstruction from the history window — and the line is offered-only.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-10, Confidence 0.9, Prior: none (new file).
//  Review: Kev + claude-fable-5.1, 2026-10-09 — the "busiest" disambiguation clause is pinned on both styles:
//  Lil (Qwen3.5) answered `tool-recent-busiest` with "which kind of busy?" ~6/16 instead of calling the tool.
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

    @Test("'busiest' / 'most active' means activity on this device — call the tool, never ask which kind of busy")
    func busiestIsNotAClarifyingQuestion() {
        for style in [AgentRAGResponder.PromptStyle.react, .native] {
            let prompt = AgentRAGResponder.grounding(
                chunks: [], toolNames: ["search_knowledge", "recent_activity"], style: style
            )
            #expect(prompt.contains("busiest"))
            #expect(prompt.contains("most active"))
            #expect(prompt.contains("do not ask which kind of busy"))
            #expect(prompt.contains("do not reconstruct it from this conversation"))
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
