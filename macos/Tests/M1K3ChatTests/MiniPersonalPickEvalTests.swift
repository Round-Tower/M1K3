//
//  MiniPersonalPickEvalTests.swift
//  M1K3ChatTests
//
//  Live, opt-in (`M1K3_AFM_EVAL=1`): Apple's tool pick on questions about what the user decided
//  or said, under master's search_knowledge menu line and this branch's, then through the
//  correctors in the responder's order. 2026-10-20: "What did Kev decide about which brain fronts
//  by default?" picked lookup_fact, and Lil invented "you picked Private Cloud Compute".
//  Needs no MLX, so it runs beside the live app.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-20, Confidence 0.7 (temperature 0, one trial per
//  question; a measure of the pick, not of the answer). Prior: none.
//

#if canImport(FoundationModels)
    import Foundation
    import M1K3Agent
    @testable import M1K3Chat
    import M1K3Inference
    import Testing

    @Suite(.enabled(if: ProcessInfo.processInfo.environment["M1K3_AFM_EVAL"] == "1"), .serialized)
    struct MiniPersonalPickEvalTests {
        private struct Stub: AgentTool {
            let name: String
            var description: String {
                name
            }

            var parameters: [ToolParameter] {
                [ToolParameter(name: "query", description: "")]
            }

            func execute(input _: [String: String]) async throws -> ToolResult {
                ToolResult(output: "")
            }
        }

        /// The MCP ask's palette, as the live log's 8-tool prefix lists it, and the chat's reads.
        private static let palettes: [String: [any AgentTool]] = [
            "mcp": [
                "datetime", "fetch_page", "get_document", "list_documents", "lookup_fact", "search_knowledge",
                "system_status", "web_search",
            ].map { Stub(name: $0) },
            "chat": [
                "datetime", "system_status", "search_knowledge", "list_documents", "web_search", "lookup_fact",
                "fetch_page", "recent_activity", "calendar_peek", "battery_status", "current_location",
            ].map { Stub(name: $0) },
        ]

        private static let masterLine = "the user's own documents, notes, files or recorded calls"

        static let personal = [
            "What did Kev decide about which brain fronts by default, and why?",
            "What did I decide about the default brain, and why?",
            "Which embedder did I pick for the iPad build?",
            "What did we agree on for the launch date?",
            "What have I told you about my sister's wedding?",
            "Do you remember what I said about the trip to Kerry?",
        ]
        static let world = [
            "What did the Supreme Court decide in Roe v Wade?",
            "Who won the All-Ireland hurling final this year?",
            "Should I pick an iPhone or a Pixel?",
            "When was Cork founded?",
        ]

        /// The Mac app's picks chain (`toolChain`, on when unset): "lookup_fact+web_search".
        static func label(_ pick: ToolPick) -> String {
            ([pick.tool] + pick.then.map(\.tool)).joined(separator: "+")
        }

        @Test("personal questions reach search_knowledge; world questions keep their web read")
        func personalPicks() async {
            let provider = AppleFoundationModelsProvider()
            guard provider.isAvailable else { return }
            var rows: [String] = []
            var corrected: [String: String] = [:]
            for (name, palette) in Self.palettes.sorted(by: { $0.key < $1.key }) {
                let newMenu = ToolDispatch.menu(palette: palette)
                let line = ToolDispatch.menuLines["search_knowledge"] ?? ""
                let oldMenu = newMenu.replacingOccurrences(of: line, with: Self.masterLine)
                for question in Self.personal + Self.world {
                    let old = await ToolRouterWiring.pick(with: provider, question: question, menu: oldMenu, chain: true)
                    let new = await ToolRouterWiring.pick(with: provider, question: question, menu: newMenu, chain: true)
                    let fixed = new.map { ToolDispatch.corrected($0, palette: palette, question: question) }
                    corrected[name + question] = fixed?.tool ?? "agent"
                    rows.append("\(name): \(old.map(Self.label) ?? "agent") → \(new.map(Self.label) ?? "agent") → \(fixed.map(Self.label) ?? "agent") | \(question)")
                }
            }
            print("PERSONALPICK master-menu → branch-menu → corrected | question\n" + rows.joined(separator: "\n"))
            let webReads: Set = ["lookup_fact", "web_search"]
            for name in Self.palettes.keys {
                for question in Self.personal {
                    #expect(!webReads.contains(corrected[name + question] ?? ""), "\(name): \(question) still goes to a web read")
                }
                for question in Self.world {
                    #expect(corrected[name + question] != "search_knowledge", "\(name): \(question) moved to the user's knowledge")
                }
            }
        }
    }
#endif
