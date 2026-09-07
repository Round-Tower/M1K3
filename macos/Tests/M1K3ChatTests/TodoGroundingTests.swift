//
//  TodoGroundingTests.swift
//  M1K3ChatTests
//
//  The todo block rides the per-turn grounding after the remembered facts
//  and before what's open beside the chat; nil leaves every pinned prompt
//  byte-identical (the BrowserContext rule, applied again).
//
//  Signed: Kev + claude-fable-5.1, 2026-09-07, Confidence 0.9. Prior: none
//  (new file).
//

import Foundation
@testable import M1K3Chat
import Testing

struct TodoGroundingTests {
    private let block = "OPEN TODOS (the user's own list):\n- Renew passport"
    private let page = "OPEN BESIDE THE CHAT:\nA page"

    @Test("the todo block sits after the memory block and before the ambient page")
    func placement() throws {
        let tools: Set = ["search_knowledge"]
        let with = AgentRAGResponder.grounding(chunks: [], toolNames: tools, style: .react, ambient: page, todos: block)
        let todos = try #require(with.range(of: "OPEN TODOS")?.lowerBound)
        let open = try #require(with.range(of: "OPEN BESIDE THE CHAT")?.lowerBound)
        let rules = try #require(with.range(of: "RULES:")?.lowerBound)
        let knowledge = try #require(with.range(of: "No stored knowledge")?.lowerBound)
        #expect(knowledge < todos && todos < open && open < rules)
    }

    @Test("a nil block is byte-identical to a build without todos")
    func nilIsIdentical() {
        let tools: Set = ["search_knowledge"]
        let with = AgentRAGResponder.grounding(chunks: [], toolNames: tools, style: .native, todos: block)
        let without = AgentRAGResponder.grounding(chunks: [], toolNames: tools, style: .native)
        #expect(!without.contains("OPEN TODOS"))
        #expect(with.replacingOccurrences(of: "\n\n" + block, with: "") == without)
    }
}
