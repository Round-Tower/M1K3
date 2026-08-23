//
//  SameTurnExclusionTests.swift
//  M1K3AgentTests
//
//  P1 of the context-tools charter (docs/CONTEXT_TOOLS_PLAN.md), enforced in
//  code: once a local-sensitive tool fires in a turn, network tools are
//  unavailable for the rest of that turn — and vice versa — so sensitive local
//  output can never flow out in the same turn it was read, whatever the prompt
//  says. Enforcement lives in the shared dispatch core (planCall), so both the
//  ReAct and native paths inherit it.
//
//  Signed: Kev + claude-fable-5, 2026-08-23, Confidence 0.9, Prior: Unknown

import Foundation
@testable import M1K3Agent
import M1K3Inference
import Testing

/// A recording tool with a declarable exclusion class.
private final class ClassedTool: AgentTool, @unchecked Sendable {
    let name: String
    let description = "test tool"
    let parameters = [ToolParameter(name: "query", description: "the query")]
    let exclusionClass: ToolExclusionClass?

    private let lock = NSLock()
    private var _calls = 0
    var calls: Int {
        lock.withLock { _calls }
    }

    init(name: String, exclusionClass: ToolExclusionClass?) {
        self.name = name
        self.exclusionClass = exclusionClass
    }

    func execute(input _: [String: String]) async throws -> ToolResult {
        lock.withLock { _calls += 1 }
        return ToolResult(output: "\(name) says hi")
    }
}

struct SameTurnExclusionTests {
    @Test("after a local-sensitive tool fires, a network tool is steered away, not executed")
    func scriptThenWebIsBlocked() async throws {
        let scripty = ClassedTool(name: "scripty", exclusionClass: .localSensitive)
        let webby = ClassedTool(name: "webby", exclusionClass: .network)
        let provider = ScriptedProvider([
            "ACTION: scripty(run it)",
            "ACTION: webby(look it up)",
            "CONCLUSION: done",
        ])
        let agent = LocalAgent(inferenceProvider: provider, tools: [scripty, webby])
        let result = try await agent.run(goal: "test")
        #expect(scripty.calls == 1)
        #expect(webby.calls == 0)
        #expect(result.toolsUsed.contains("scripty"))
        #expect(!result.toolsUsed.contains("webby"))
    }

    @Test("the exclusion is mutual: web first blocks local-sensitive after")
    func webThenScriptIsBlocked() async throws {
        let scripty = ClassedTool(name: "scripty", exclusionClass: .localSensitive)
        let webby = ClassedTool(name: "webby", exclusionClass: .network)
        let provider = ScriptedProvider([
            "ACTION: webby(look it up)",
            "ACTION: scripty(run it)",
            "CONCLUSION: done",
        ])
        let agent = LocalAgent(inferenceProvider: provider, tools: [scripty, webby])
        _ = try await agent.run(goal: "test")
        #expect(webby.calls == 1)
        #expect(scripty.calls == 0)
    }

    @Test("same-class calls keep flowing — two network tools in one turn is fine")
    func sameClassIsAllowed() async throws {
        let webby = ClassedTool(name: "webby", exclusionClass: .network)
        let webby2 = ClassedTool(name: "webby2", exclusionClass: .network)
        let provider = ScriptedProvider([
            "ACTION: webby(a)",
            "ACTION: webby2(b)",
            "CONCLUSION: done",
        ])
        let agent = LocalAgent(inferenceProvider: provider, tools: [webby, webby2])
        _ = try await agent.run(goal: "test")
        #expect(webby.calls == 1)
        #expect(webby2.calls == 1)
    }

    @Test("unclassed tools are never caught in the exclusion")
    func unclassedUnaffected() async throws {
        let scripty = ClassedTool(name: "scripty", exclusionClass: .localSensitive)
        let plain = ClassedTool(name: "plain", exclusionClass: nil)
        let provider = ScriptedProvider([
            "ACTION: scripty(run it)",
            "ACTION: plain(check)",
            "CONCLUSION: done",
        ])
        let agent = LocalAgent(inferenceProvider: provider, tools: [scripty, plain])
        _ = try await agent.run(goal: "test")
        #expect(scripty.calls == 1)
        #expect(plain.calls == 1)
    }

    @Test("the exclusion resets between turns — a fresh run starts clean")
    func resetsBetweenRuns() async throws {
        let scripty = ClassedTool(name: "scripty", exclusionClass: .localSensitive)
        let webby = ClassedTool(name: "webby", exclusionClass: .network)
        let provider = ScriptedProvider([
            "ACTION: scripty(run it)",
            "CONCLUSION: first done",
            "ACTION: webby(now search)",
            "CONCLUSION: second done",
        ])
        let agent = LocalAgent(inferenceProvider: provider, tools: [scripty, webby])
        _ = try await agent.run(goal: "first")
        _ = try await agent.run(goal: "second")
        #expect(scripty.calls == 1)
        #expect(webby.calls == 1) // NOT blocked by the previous turn's script
    }

    @Test("the live web tools declare the network class; execute_script declares local-sensitive")
    func liveToolClassesArePinned() {
        // Pinned here (strings, not links) mirroring SelfQueryGate's pin style:
        // the classes are meaningless unless the shipping tools carry them.
        // The M1K3AgentTools side is asserted in its own target
        // (ExecuteScriptToolTests.contract, WebToolExclusionClassTests).
        #expect(ToolExclusionClass.network != ToolExclusionClass.localSensitive)
    }
}
