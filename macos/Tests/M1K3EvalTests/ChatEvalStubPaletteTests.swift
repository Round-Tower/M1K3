//
//  ChatEvalStubPaletteTests.swift
//  M1K3EvalTests
//
//  Signed: Kev + claude-fable-5.1, 2026-09-10, Confidence 0.85. Prior: Unknown.
//

@testable import M1K3Eval
import Testing

struct ChatEvalStubPaletteTests {
    @Test("every tool a tool-use fixture requires exists in the stub palette (#233)")
    func fixturesNameOnlyPaletteTools() {
        // The two-month bug: tool-read-site required fetch_page, no stub offered
        // it, and the scorer's exact-name membership made the fixture unpassable
        // for EVERY brain — silently counted in every published tool-use cell.
        let names = Set(ChatEvalStubPalette.names)
        for fixture in ChatEvalFixtures.toolUse {
            let tool = fixture.expectation.mustCallTool ?? ""
            #expect(names.contains(tool), "\(fixture.id) requires \(tool), which no stub offers")
        }
    }

    @Test("stub names are unique and each parameter is named as the production tool names it")
    func shapes() {
        let names = ChatEvalStubPalette.names
        #expect(Set(names).count == names.count)
        // Mirrors Sources/M1K3AgentTools: DateTimeTool (`query`, ignored),
        // SearchKnowledgeTool/WebSearchTool (`query`), WikipediaTool (`topic`),
        // FetchPageTool (`url`). Review 2 on #263: the eval must pay the same
        // schema cost the app pays, or PromptSizeStage measures a fiction.
        let expected: [String: String] = [
            "datetime": "query", "search_knowledge": "query", "lookup_fact": "topic",
            "web_search": "query", "fetch_page": "url",
        ]
        for spec in ChatEvalStubPalette.specs {
            #expect(spec.parameter?.name == expected[spec.name], "\(spec.name) declares \(spec.parameter?.name ?? "nil")")
        }
        for spec in ChatEvalStubPalette.specs where spec.name != "datetime" {
            #expect(spec.canned.contains("{input}"), "\(spec.name)'s terminal output should echo the argument")
        }
    }

    @Test("every parameter is one the AFM arm can express — query, url, or none")
    func afmArmCanExpressEveryParameter() {
        // ChatEvalStage.afmTool dispatches on the parameter NAME to pick a
        // @Generable argument shape, and its default branch assumes `query`. A
        // stub with a differently named parameter would compile and silently
        // drift the two palettes apart (review 1 on #263) — so it fails here.
        for spec in ChatEvalStubPalette.specs {
            let name = spec.parameter?.name
            #expect(name == nil || name == "query" || name == "url" || name == "topic",
                    "\(spec.name) declares \(name ?? "nil"), which the AFM arm cannot express")
        }
    }

    @Test("terminal output resolves; hard output for the lookup tools does not")
    func outputs() throws {
        let web = try #require(ChatEvalStubPalette.specs.first { $0.name == "web_search" })
        #expect(web.output(for: "Apple Silicon", hard: false).contains("Apple Silicon"))
        #expect(web.output(for: "x", hard: false).contains("No further search needed"))
        #expect(web.output(for: "x", hard: true).contains("open a result"))
        let fact = try #require(ChatEvalStubPalette.specs.first { $0.name == "lookup_fact" })
        #expect(fact.output(for: "x", hard: true).isEmpty)
        let fetch = try #require(ChatEvalStubPalette.specs.first { $0.name == "fetch_page" })
        #expect(fetch.output(for: "m1k3.app", hard: false).hasPrefix("Page: "))
        #expect(fetch.output(for: "m1k3.app", hard: true).contains("Do not describe"))
    }
}
