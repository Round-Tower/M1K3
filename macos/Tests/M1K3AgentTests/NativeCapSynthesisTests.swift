//
//  NativeCapSynthesisTests.swift
//  M1K3AgentTests
//
//  The iteration cap never claims evidence it doesn't have. Found by the 2026-10-07 empty-turn
//  challenge: a run of empty `.toolCalls([])` turns steered into the cap, whose synthesis then
//  returned "I gathered some information but couldn't form a final answer." with nothing
//  gathered — a false message the responder showed instead of falling back.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-07, Confidence 0.9, Prior: none (new file).

import Foundation
@testable import M1K3Agent
import M1K3Inference
import Testing

private final class NoopTool: AgentTool, @unchecked Sendable {
    let name = "search"
    let description = "noop"
    let parameters = [ToolParameter(name: "query", description: "q")]
    func execute(input _: [String: String]) async throws -> ToolResult {
        ToolResult(output: "evidence")
    }
}

struct NativeCapSynthesisTests {
    @Test("gathered observations are the tool results, or empty — never a false 'gathered' line")
    func honestObservations() {
        #expect(LocalAgent.gatheredObservations(from: [.user("x", images: [])]) == "")
        #expect(LocalAgent.gatheredObservations(from: [.toolResult(name: "s", output: "fact")]) == "fact")
    }

    @Test("empty turns into the cap conclude empty, so the responder's fallback answers")
    func emptyTurnsIntoCapConcludeEmpty() async throws {
        let provider = FakeToolCallingProvider { _, _, _ in .toolCalls([]) }
        let result = try await LocalAgent(inferenceProvider: provider, tools: [NoopTool()], maxIterations: 2)
            .run(goal: "x")
        #expect(result.conclusion == "")
    }
}
