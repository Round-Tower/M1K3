//
//  SearchPickEvalTests.swift
//  M1K3ChatTests
//
//  Live, opt-in (`M1K3_AFM_EVAL=1`): does a turn reach the web, under the picker wording this build
//  ships and under candidate wordings? Every line takes the app's own route for a fresh chat turn on
//  the Mac (#713): the gate (ToolNeedRouter), then the group head, else Apple's picker with chains on,
//  then the correctors (`ToolDispatch.corrected`). The search head ships as a stub that never vetoes,
//  and no document chunk is kept, so neither moves a pick here. Only the picker's wording varies, so
//  only a line that reaches the picker can move. Needs no MLX, so it runs beside the live app.
//
//  Sets (`M1K3_SEARCHPICK_SET`: dev, test or all; default test):
//  - dev: the search head's labelled pool (tools/router/data/search_head_train.json, 824 lines,
//    teacher-labelled, never the picker's). Candidate wordings are drafted and chosen on it.
//  - test: lines no candidate saw. Should search: the tool-use fixtures that need a web read. Should
//    stay local: world knowledge, the #680 lines, open chat, humour, the tool-use fixtures that need
//    only local tools, and the power receipt's ten built-in questions ("no web", 2026-10-27, yet the
//    tenth went to the web on every tier).
//
//  Candidates come from a JSON file (`M1K3_SEARCHPICK_VARIANTS`: [{name, instructions?, menuLines?}],
//  each field replacing the shipped one); the shipped wording always runs, named "shipped". Rows go
//  to `M1K3_SEARCHPICK_OUT` as JSON; a summary prints per variant and set.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.75 (temperature 0, one trial per line;
//  it measures the route's pick, not the answer, and the dev labels are a teacher's). Prior: none
//  (new file; MiniPersonalPickEvalTests' shape).
//

#if canImport(FoundationModels)
    import Foundation
    import M1K3Agent
    @testable import M1K3Chat
    import M1K3Eval
    import M1K3Inference
    import Testing

    @Suite(.enabled(if: ProcessInfo.processInfo.environment["M1K3_AFM_EVAL"] == "1"), .serialized)
    struct SearchPickEvalTests {
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

        /// The Mac chat's read-only tools, as MiniPersonalPickEvalTests lists them.
        private static let palette: [any AgentTool] = [
            "datetime", "system_status", "search_knowledge", "list_documents", "web_search", "lookup_fact",
            "fetch_page", "recent_activity", "calendar_peek", "battery_status", "current_location",
        ].map { Stub(name: $0) }

        struct Line: Codable, Equatable {
            let prompt: String
            let search: Bool
            let set: String
            let group: String
        }

        struct Variant: Codable {
            let name: String
            let instructions: String?
            let menuLines: [String: String]?
        }

        struct Row: Codable {
            let prompt: String
            let search: Bool
            let set: String
            let group: String
            let gateP: Double?
            /// plain (the gate said chat), head (the group head named the pick) or picker.
            let stage: String
            /// Per variant: the corrected pick ("web_search", "lookup_fact+web_search", "none", "agent").
            let picks: [String: String]
        }

        /// The power receipt's built-in questions (tools/eval/power_receipt.py), meant to need no web.
        static let receiptQuestions = [
            "In one sentence, what is a knowledge graph?",
            "Give me three tips for focusing on a long task.",
            "Explain what a hash function is, briefly.",
            "What's a good name for a fox who fixes computers? One or two suggestions.",
            "Summarise the plot of Frankenstein in two sentences.",
            "How do I boil an egg so the yolk is jammy?",
            "What's the difference between weather and climate?",
            "Write a haiku about a quiet machine.",
            "Why is the sky blue? Keep it short.",
            "List four uses for a Raspberry Pi.",
        ]

        static func testLines() -> [Line] {
            func needsWeb(_ fixture: ChatEvalFixture) -> Bool {
                let required = (fixture.expectation.mustCallTool.map { [$0] } ?? []) + fixture.expectation.alsoCallTools
                return required.contains { ToolDispatch.webSourced.contains($0) }
            }
            let tools = ChatEvalFixtures.toolUse.map { Line(prompt: $0.prompt, search: needsWeb($0), set: "test", group: "tool-use") }
            let local: [(String, [String])] = [
                ("world", ChatEvalFixtures.worldKnowledge.map(\.prompt)),
                ("issue-680", SearchRouterFixtureTests.issue680Lines),
                ("open-chat", ChatEvalFixtures.openChat.map(\.prompt)),
                ("humour", ChatEvalFixtures.humour.map(\.prompt)),
                ("receipt", receiptQuestions),
            ]
            return tools + local.flatMap { group, prompts in
                prompts.map { Line(prompt: $0, search: false, set: "test", group: group) }
            }
        }

        static func devLines() throws -> [Line] {
            var root = URL(filePath: #filePath).deletingLastPathComponent()
            while !FileManager.default.fileExists(atPath: root.appending(path: "Package.swift").path) {
                root = root.deletingLastPathComponent()
                try #require(root.path != "/", "no Package.swift above \(#filePath)")
            }
            let data = try Data(contentsOf: root.appending(path: "tools/router/data/search_head_train.json"))
            let items = try #require(
                (JSONSerialization.jsonObject(with: data) as? [String: Any])?["items"] as? [[String: Any]]
            )
            return items.compactMap { item in
                guard let prompt = item["prompt"] as? String, let search = item["search"] as? Bool else { return nil }
                return Line(prompt: prompt, search: search, set: "dev", group: item["group"] as? String ?? item["source"] as? String ?? "-")
            }
        }

        /// The picker's full instructions for a variant: its rules (or the shipped ones), the chain
        /// exception (the Mac ships chains on), and the menu with its lines swapped in.
        static func instructions(_ variant: Variant) -> String {
            var menu = ToolDispatch.menu(palette: palette)
            for (tool, line) in variant.menuLines ?? [:] {
                guard let shipped = ToolDispatch.menuLines[tool] else { continue }
                menu = menu.replacingOccurrences(of: "\(tool): \(shipped)", with: "\(tool): \(line)")
            }
            let rules = variant.instructions ?? ToolDispatch.pickerInstructions
            return rules + "\n" + ToolDispatch.chainInstructions + "\n\n" + menu
        }

        static func label(_ pick: ToolPick?) -> String {
            guard let pick else { return "agent" }
            return ([pick.tool] + pick.then.map(\.tool)).joined(separator: "+")
        }

        static func readsWeb(_ label: String) -> Bool {
            label.split(separator: "+").contains { ToolDispatch.webSourced.contains(String($0)) }
        }

        @Test("which turns reach the web, by picker wording")
        func searchPicks() async throws {
            let env = ProcessInfo.processInfo.environment
            let provider = AppleFoundationModelsProvider()
            guard provider.isAvailable else { return }
            let set = env["M1K3_SEARCHPICK_SET"] ?? "test"
            var lines: [Line] = []
            if set == "dev" || set == "all" { lines += try Self.devLines() }
            if set == "test" || set == "all" { lines += Self.testLines() }
            var variants = [Variant(name: "shipped", instructions: nil, menuLines: nil)]
            if let path = env["M1K3_SEARCHPICK_VARIANTS"] {
                variants += try JSONDecoder().decode([Variant].self, from: Data(contentsOf: URL(filePath: path)))
            }
            let embedder = NLSentenceEmbedder()
            var rows: [Row] = []
            for line in lines {
                let gate = ToolNeedRouter.decide(for: line.prompt, embed: embedder.vector)
                var picks: [String: String] = [:]
                var stage = "picker"
                if gate.verdict == .chat {
                    stage = "plain"
                    for variant in variants {
                        picks[variant.name] = "plain"
                    }
                } else if let head = ToolGroupRouter.pick(for: line.prompt, embed: embedder.vector, chain: true) {
                    stage = "head"
                    let corrected = ToolDispatch.corrected(head, palette: Self.palette, question: line.prompt)
                    for variant in variants {
                        picks[variant.name] = Self.label(corrected)
                    }
                } else {
                    // The variants ask at once: each pick is its own fresh session, so they don't interact.
                    picks = await withTaskGroup(of: (String, String).self) { group in
                        for variant in variants {
                            let instructions = Self.instructions(variant)
                            group.addTask {
                                let picked = try? await provider.pickTools(message: line.prompt, instructions: instructions)
                                let pick = picked?.first.map { first in
                                    ToolPick(
                                        tool: first.tool, query: first.query,
                                        then: (picked ?? []).dropFirst().map { ToolPick(tool: $0.tool, query: $0.query) }
                                    )
                                }
                                let fixed = pick.map { ToolDispatch.corrected($0, palette: Self.palette, question: line.prompt) }
                                return (variant.name, Self.label(fixed))
                            }
                        }
                        var named: [String: String] = [:]
                        for await (name, label) in group {
                            named[name] = label
                        }
                        return named
                    }
                }
                rows.append(Row(
                    prompt: line.prompt, search: line.search, set: line.set, group: line.group,
                    gateP: gate.probability, stage: stage, picks: picks
                ))
            }
            if let out = env["M1K3_SEARCHPICK_OUT"] {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(rows).write(to: URL(filePath: out))
            }
            var summary = ["SEARCHPICK variant · set · searched when it shouldn't · kept local when it should search"]
            for variant in variants {
                for name in Set(rows.map(\.set)).sorted() {
                    let mine = rows.filter { $0.set == name }
                    let local = mine.filter { !$0.search }
                    let web = mine.filter(\.search)
                    let wrongWeb = local.filter { Self.readsWeb($0.picks[variant.name] ?? "") }.count
                    let missed = web.filter { !Self.readsWeb($0.picks[variant.name] ?? "") }.count
                    summary.append("\(variant.name) · \(name) · \(wrongWeb)/\(local.count) · \(missed)/\(web.count)")
                }
            }
            print(summary.joined(separator: "\n"))
            #expect(!rows.isEmpty)
        }
    }
#endif
