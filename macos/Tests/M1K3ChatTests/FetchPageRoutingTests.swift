//
//  FetchPageRoutingTests.swift
//  M1K3ChatTests
//
//  Pins the page-tool routing lines on the ASSEMBLED prompt: a user-given
//  address is read with fetch_page (never searched for), the describe-only rule
//  appears exactly once however many page tools are offered, and no line ever
//  names a tool that isn't offered. Written red-first off the 2026-09-04 live
//  replay (see the doc comment on the suite).
//
//  Signed: Kev + claude-fable-5.1, 2026-09-04, Confidence 0.9, Prior: Unknown

import Foundation
@testable import M1K3Chat
import Testing

/// The routing line that makes a user-given address a READ, not a search.
/// Live replay 2026-09-04: asked to "fetch the web site m1k3.app", Lil ran
/// web_search("m1k3.app website content and features") — the rules only ever
/// told it that web_search reads the top result and fetch_page is for a
/// DIFFERENT result — then blended corpus chunks about the Android app into
/// its read of the Mac site. Offered-only, like every routing line.
struct FetchPageRoutingTests {
    private let webTools: Set<String> = ["web_search", "search_knowledge", "fetch_page"]

    @Test("with fetch_page offered, an address the user gives is read directly, never searched for")
    func directAddressLineWhenOffered() {
        for style in [AgentRAGResponder.PromptStyle.react, .native] {
            let prompt = AgentRAGResponder.grounding(chunks: [], toolNames: webTools, style: style)
            #expect(prompt.contains(AgentRAGResponder.fetchPageRouting))
            #expect(prompt.contains("read it directly with fetch_page"))
            #expect(prompt.contains("Describe a page only from what a tool returned"))
        }
    }

    @Test("without fetch_page, no rule names it")
    func absentWhenNotOffered() {
        let prompt = AgentRAGResponder.grounding(
            chunks: [], toolNames: ["web_search", "search_knowledge"], style: .react
        )
        #expect(!prompt.contains("fetch_page"))
    }

    @Test("open_link without fetch_page never tells the model to read with a tool it can't call")
    func openLinkWithoutFetchPage() {
        let prompt = AgentRAGResponder.grounding(
            chunks: [], toolNames: ["search_knowledge", "open_link"], style: .react
        )
        #expect(prompt.contains("open_link shows a page beside the chat"))
        #expect(!prompt.contains("fetch_page"))
        #expect(prompt.contains("Describe a page only from what a tool returned"))
    }

    @Test("with open_link offered too, the describe-only rule appears once — on the assembled prompt")
    func describeOnlyRuleIsNotDuplicated() {
        let prompt = AgentRAGResponder.grounding(
            chunks: [], toolNames: webTools.union(["open_link"]), style: .react
        )
        let needle = "Describe a page only from what a tool returned"
        #expect(prompt.components(separatedBy: needle).count - 1 == 1)
        #expect(prompt.contains(AgentRAGResponder.openLinkRouting))
        #expect(prompt.contains(AgentRAGResponder.fetchPageRouting))
    }
}
