//
//  WebAndMakingRoutingTests.swift
//  M1K3ChatTests
//
//  Pins the per-turn lines behind Kev's 2026-09-12 report ("isn't searching the
//  internet much, or really invoking tools — and coding / document generation is
//  not being invoked") on the ASSEMBLED prompt, in both styles: the newest or an
//  unrecognised thing is a web search, a web page or a document is written as a
//  fenced block (never a script), and "how busy it's been" is recent_activity.
//  The wording is the byte-replayed winner (Lil, n=4 per probe); these pins keep
//  a later edit from quietly undoing it.
//
//  Signed: Kev + claude-opus-5, 2026-09-12, Confidence 0.85, Prior: none (new file).
//

import Foundation
@testable import M1K3Chat
import Testing

struct WebAndMakingRoutingTests {
    private static let palette: Set<String> = [
        "web_search", "search_knowledge", "lookup_fact", "propose_script", "recent_activity",
    ]

    @Test("the web route covers the newest, this year's results, and names it doesn't recognise")
    func webRouteCoversTheNewAndTheUnknown() {
        for style in [AgentRAGResponder.PromptStyle.react, .native] {
            let prompt = AgentRAGResponder.grounding(chunks: [], toolNames: Self.palette, style: style)
            #expect(prompt.contains(AgentRAGResponder.currentWorldRouting), "\(style)")
            #expect(prompt.contains("the newest or latest of anything"), "\(style)")
            #expect(prompt.contains("a name you don't recognise"), "\(style)")
            #expect(prompt.contains("even when notes were injected above"), "\(style)")
            #expect(prompt.contains("Before saying something doesn't exist or hasn't happened, search."))
            // Stable facts are answered from memory — never the newest of anything.
            #expect(prompt.contains("basic science — never the newest of anything"), "\(style)")
        }
    }

    @Test("without web_search, the web route is not offered")
    func noWebRouteWithoutWebSearch() {
        let prompt = AgentRAGResponder.grounding(
            chunks: [], toolNames: ["search_knowledge"], style: .native
        )
        #expect(!prompt.contains(AgentRAGResponder.currentWorldRouting))
        #expect(!prompt.contains("web_search"))
    }

    @Test("the carve names building and making, and a CAN-you question is answered by doing it")
    func carveHeadNamesMaking() {
        for carve in [AgentRAGResponder.generativeCarveOut, AgentRAGResponder.generativeCarveOutWithScripts] {
            #expect(carve.hasPrefix(AgentRAGResponder.generativeCarveHead))
            #expect(carve.contains("write, build, make, create, code, or compose"))
            #expect(carve.contains("a whole web page"))
            #expect(carve.contains("Asked whether you CAN make it, make it."))
        }
    }

    @Test("with the hands offered, a web page or a document is a fenced block, not a script")
    func webPageIsNotAScript() {
        let scripts = AgentRAGResponder.generativeCarveOutWithScripts
        #expect(scripts.contains("A web page or a document is not a script"))
        #expect(scripts.contains("```html or ```markdown block"))
        // The plain carve has no script tool to steer away from.
        #expect(!AgentRAGResponder.generativeCarveOut.contains("not a script"))
    }

    @Test("'how busy it's been' routes to recent_activity")
    func busyRoutesToRecentActivity() {
        #expect(AgentRAGResponder.recentActivityRouting.contains("how busy it's been"))
    }
}
