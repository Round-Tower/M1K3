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

    @Test("stub names are unique and fetch_page takes a url, datetime takes nothing")
    func shapes() {
        let names = ChatEvalStubPalette.names
        #expect(Set(names).count == names.count)
        let fetch = ChatEvalStubPalette.specs.first { $0.name == "fetch_page" }
        #expect(fetch?.parameter?.name == "url")
        let datetime = ChatEvalStubPalette.specs.first { $0.name == "datetime" }
        #expect(datetime != nil)
        #expect(datetime?.parameter == nil, "datetime is a zero-argument tool in production; asking for a query cost the 1.2B a call")
        for spec in ChatEvalStubPalette.specs where spec.parameter != nil {
            #expect(spec.canned.contains("{input}"), "\(spec.name)'s terminal output should echo the argument")
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
