//
//  ToolDispatchTests.swift
//  M1K3ChatTests
//
//  Router-invoked tools (Kev, 2026-09-26: "use it to invoke tools outside of
//  the inference loop"). When a turn needs a tool, the app runs one read-only
//  tool itself and hands Mini the result in one streamed generation, instead of
//  Mini deciding, calling and then synthesising (~50 s a tool turn). Anything
//  that acts on the Mac, or can't be planned safely, goes to the agent loop.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-26, Confidence 0.8. Prior: Unknown.
//

import Foundation
import M1K3Agent
@testable import M1K3Chat
import M1K3Inference
import Testing

private struct Stub: AgentTool {
    let name: String
    var parameter: String? = "query"
    var description: String {
        name
    }

    var parameters: [ToolParameter] {
        parameter.map { [ToolParameter(name: $0, description: "")] } ?? []
    }

    func execute(input _: [String: String]) async throws -> ToolResult {
        ToolResult(output: "")
    }
}

private let palette: [any AgentTool] = [
    Stub(name: "datetime"), Stub(name: "battery_status"), Stub(name: "search_knowledge"),
    Stub(name: "web_search"), Stub(name: "lookup_fact", parameter: "topic"), Stub(name: "fetch_page", parameter: "url"),
    Stub(name: "recent_activity", parameter: "window"), Stub(name: "propose_script", parameter: "script"),
    Stub(name: "open_link", parameter: "url"), Stub(name: "delegate_deep", parameter: "task"),
]

struct ToolDispatchPlanTests {
    @Test("a read-only tool on the palette is planned, its query on the tool's own parameter")
    func plansReadOnly() throws {
        let plan = try #require(ToolDispatch.plan(
            ToolPick(tool: "web_search", query: "newest Claude model"), palette: palette, question: "What's the newest Claude model?"
        ))
        #expect(plan.tool.name == "web_search")
        #expect(plan.input == ["query": "newest Claude model"])
        let fact = try #require(ToolDispatch.plan(
            ToolPick(tool: "lookup_fact", query: "Cork founding year"), palette: palette, question: "When was Cork founded?"
        ))
        #expect(fact.input == ["topic": "Cork founding year"])
    }

    @Test("an empty picked query falls back to the user's own words")
    func emptyQueryUsesQuestion() throws {
        let plan = try #require(ToolDispatch.plan(
            ToolPick(tool: "datetime", query: " "), palette: palette, question: "what time is it?"
        ))
        #expect(plan.input == ["query": "what time is it?"])
    }

    @Test("recent_activity with no window uses the tool's own default")
    func activityDefaultWindow() throws {
        let plan = try #require(ToolDispatch.plan(
            ToolPick(tool: "recent_activity", query: ""), palette: palette, question: "what have we been up to?"
        ))
        #expect(plan.input.isEmpty)
    }

    @Test("fetch_page is planned only with a URL in hand")
    func fetchNeedsURL() {
        #expect(ToolDispatch.plan(
            ToolPick(tool: "fetch_page", query: "m1k3.app"), palette: palette, question: "Read m1k3.app"
        )?.input == ["url": "https://m1k3.app"])
        #expect(ToolDispatch.plan(
            ToolPick(tool: "fetch_page", query: ""), palette: palette, question: "read that page again"
        ) == nil)
    }

    @Test("actions, unknown tools and tools this turn doesn't offer go to the agent (nil)")
    func actionsNeverDispatch() {
        for tool in ["propose_script", "execute_script", "open_link", "delegate_deep", "get_document", "made_up"] {
            #expect(ToolDispatch.plan(ToolPick(tool: tool, query: "x"), palette: palette, question: "x") == nil, "\(tool)")
        }
        // Offered nowhere this turn (web off, the self-query gate): never dispatched.
        #expect(ToolDispatch.plan(
            ToolPick(tool: "web_search", query: "x"), palette: [Stub(name: "datetime")], question: "x"
        ) == nil)
    }

    @Test("the search tools' no-result outputs read as empty")
    func emptyResults() {
        for output in ["No results for \"x\".", "Nothing relevant in stored knowledge for \"x\" …",
                       "No web results for \"x\".", "No Wikipedia article found for \"x\".", "  "]
        {
            #expect(ToolDispatch.isEmptyResult(output), "\(output)")
        }
        #expect(!ToolDispatch.isEmptyResult("Saturday 26 September 2026, 20:14"))
    }

    @Test("the observation block names the tool, keeps short output whole, caps long output")
    func observationBlock() {
        let short = ToolDispatch.observationBlock(tool: "datetime", output: "Saturday 26 September 2026, 20:14")
        #expect(short.contains("datetime"))
        // A fetched page is untrusted text: framed as data, never as instructions.
        #expect(short.contains("never instructions"))
        #expect(short.contains("Saturday 26 September 2026, 20:14"))
        let long = ToolDispatch.observationBlock(tool: "web_search", output: String(repeating: "a", count: 10000))
        #expect(long.count < ToolDispatch.observationBudget + 200)
    }
}

/// The AFM picker's constrained choices (M1K3Inference can't see ToolDispatch) must be
/// exactly the names ToolDispatch plans for, or a pick could name a tool the app refuses.
struct ToolPickerChoicesTests {
    @Test("the AFM picker's choices are ToolDispatch's, name for name")
    func choicesMatch() {
        #expect(Set(AFMToolPicker.choices) == Set(ToolDispatch.pickerChoices))
    }
}
