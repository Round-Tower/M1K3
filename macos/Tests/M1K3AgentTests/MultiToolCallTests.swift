//
//  MultiToolCallTests.swift
//  M1K3AgentTests
//
//  Pins the native loop's MULTI-call turn: upstream's ToolCallProcessor emits
//  one .toolCall event per tag pair, so a single generation can carry N calls —
//  the plumbing was array-shaped end to end, but nothing ever tested the
//  fan-out (2026-08-15 finding: zero multi-call cases in NativeToolCallingTests)
//  and execution was strictly sequential. These tests pin: every call in the
//  batch executes; observations return in EMISSION order (load-bearing — the
//  model correlates result-to-call by turn order, MLXToolCalling's documented
//  contract); the repeat-guard holds WITHIN a batch; independent tools really
//  overlap; and exclusive-compute tools (the MLX-touching ones) never do.
//
//  Signed: Kev + claude-fable-5, 2026-08-15, Confidence 0.85 (the overlap test
//  proves concurrency by construction — a serial loop cannot pass it without
//  timing out; the exclusive test bounds concurrency with a live counter).
//  Prior: Unknown.

import Foundation
@testable import M1K3Agent
import M1K3Inference
import Synchronization
import Testing

private func call(_ name: String, _ args: [String: JSONValue] = [:]) -> ToolTurn {
    .toolCalls([ParsedToolCall(name: name, arguments: args)])
}

/// Scripts turns like NativeToolCallingTests' fake, kept local (that one's
/// siblings are private to its file).
private final class BatchScriptedProvider: ToolCallingProvider, @unchecked Sendable {
    let name = "scripted"
    let isAvailable = true
    let supportsToolCalls = true
    private let handler: @Sendable (Int) -> ToolTurn
    private let lock = NSLock()
    private var index = 0
    private(set) var receivedTranscripts: [[ToolMessage]] = []

    init(handler: @escaping @Sendable (Int) -> ToolTurn) {
        self.handler = handler
    }

    func continueToolTurn(messages: [ToolMessage], tools _: [ToolDefinition]) async throws -> ToolTurn {
        lock.withLock {
            receivedTranscripts.append(messages)
            defer { index += 1 }
            return handler(index)
        }
    }

    func generate(prompt _: String) async throws -> String {
        "CONCLUSION: x"
    }

    func generateStreaming(prompt _: String) -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }
}

private final class CountingTool: AgentTool, @unchecked Sendable {
    let name: String
    let description = "counts"
    let parameters = [ToolParameter(name: "query", description: "p")]
    private let lock = NSLock()
    private(set) var executionCount = 0

    init(name: String) {
        self.name = name
    }

    func execute(input: [String: String]) async throws -> ToolResult {
        lock.withLock { executionCount += 1 }
        return ToolResult(output: "\(name)-ran[\(input["query"] ?? "")]")
    }
}

/// One-shot signal two tools coordinate through, to prove overlap. Every
/// waiter's continuation is resumed exactly once — by the signal (true) or by
/// its own timeout task (false) — so a sequential executor FAILS this test
/// cleanly instead of hanging it (the first draft's task-group race deadlocked:
/// a group can't return until every child finishes, and the arrival child never
/// did).
private actor OverlapSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Bool, Never>] = []

    func signal() {
        signaled = true
        for waiter in waiters {
            waiter.resume(returning: true)
        }
        waiters.removeAll()
    }

    /// True if the signal arrived before the deadline.
    func waitForSignal(upTo deadline: Duration) async -> Bool {
        if signaled { return true }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
            Task { [weak self] in
                try? await Task.sleep(for: deadline)
                await self?.timeOutPendingWaiters()
            }
        }
    }

    private func timeOutPendingWaiters() {
        for waiter in waiters {
            waiter.resume(returning: false)
        }
        waiters.removeAll()
    }
}

/// Tracks how many executions are in flight at once.
private actor ConcurrencyGauge {
    private var active = 0
    private(set) var peak = 0

    func enter() {
        active += 1
        peak = max(peak, active)
    }

    func exit() {
        active -= 1
    }
}

struct MultiToolCallTests {
    @Test("every call in a multi-call turn executes, results in emission order")
    func multiCallFanOut() async throws {
        let provider = BatchScriptedProvider { index in
            index == 0
                ? .toolCalls([
                    ParsedToolCall(name: "alpha", arguments: ["query": .string("one")]),
                    ParsedToolCall(name: "beta", arguments: ["query": .string("two")]),
                    ParsedToolCall(name: "gamma", arguments: ["query": .string("three")]),
                ])
                : .text("done")
        }
        let tools = [CountingTool(name: "alpha"), CountingTool(name: "beta"), CountingTool(name: "gamma")]
        let agent = LocalAgent(inferenceProvider: provider, tools: tools)

        let result = try await agent.run(goal: "x")

        for tool in tools {
            #expect(tool.executionCount == 1, "tool \(tool.name)")
        }
        #expect(result.toolsUsed.sorted() == ["alpha", "beta", "gamma"])
        // Trace steps keep emission order regardless of completion order.
        let actions = result.reasoningTrace.compactMap(\.action)
        #expect(actions.count == 3)
        #expect(actions[0].contains("alpha"))
        #expect(actions[1].contains("beta"))
        #expect(actions[2].contains("gamma"))
        // The NEXT generation's delta carries the three results in the same
        // order — the model correlates result-to-call by position.
        let secondSend = provider.receivedTranscripts[1]
        let toolResults: [(String, String)] = secondSend.compactMap {
            if case let .toolResult(name, output) = $0 { return (name, output) }
            return nil
        }
        #expect(toolResults.map(\.0) == ["alpha", "beta", "gamma"])
        #expect(toolResults[1].1.contains("beta-ran[two]"))
    }

    @Test("independent tools in one batch really run concurrently")
    func independentToolsOverlap() async throws {
        // Emission order puts the WAITER first: a sequential executor would run
        // it to its timeout before the signaler ever starts, so only genuine
        // overlap produces "signaled".
        let signal = OverlapSignal()
        let waiter = ClosureTool(name: "waiter") {
            await signal.waitForSignal(upTo: .seconds(3)) ? "signaled" : "timed-out"
        }
        let signaler = ClosureTool(name: "signaler") {
            await signal.signal()
            return "sent"
        }
        let provider = BatchScriptedProvider { index in
            index == 0
                ? .toolCalls([
                    ParsedToolCall(name: "waiter", arguments: [:]),
                    ParsedToolCall(name: "signaler", arguments: [:]),
                ])
                : .text("done")
        }
        let agent = LocalAgent(inferenceProvider: provider, tools: [waiter, signaler])

        let result = try await agent.run(goal: "x")

        let observations = result.reasoningTrace.compactMap(\.observation)
        #expect(observations.contains("signaled"))
    }

    @Test("a duplicate call inside one batch hits the repeat-guard, not the tool")
    func duplicateWithinBatchGuarded() async throws {
        let provider = BatchScriptedProvider { index in
            index == 0
                ? .toolCalls([
                    ParsedToolCall(name: "alpha", arguments: ["query": .string("same")]),
                    ParsedToolCall(name: "alpha", arguments: ["query": .string("same")]),
                ])
                : .text("done")
        }
        let tool = CountingTool(name: "alpha")
        let agent = LocalAgent(inferenceProvider: provider, tools: [tool])

        let result = try await agent.run(goal: "x")

        #expect(tool.executionCount == 1)
        let observations = result.reasoningTrace.compactMap(\.observation)
        #expect(observations.count == 2)
        #expect(observations[1].contains("already ran"))
    }

    @Test("exclusive-compute tools never overlap each other")
    func exclusiveToolsSerialize() async throws {
        let gauge = ConcurrencyGauge()
        let makeExclusive: (String) -> ClosureTool = { name in
            let tool = ClosureTool(name: name) {
                await gauge.enter()
                try? await Task.sleep(for: .milliseconds(30))
                await gauge.exit()
                return "\(name)-done"
            }
            tool.requiresExclusiveComputeOverride = true
            return tool
        }
        let provider = BatchScriptedProvider { index in
            index == 0
                ? .toolCalls([
                    ParsedToolCall(name: "mlx-one", arguments: [:]),
                    ParsedToolCall(name: "mlx-two", arguments: [:]),
                ])
                : .text("done")
        }
        let agent = LocalAgent(
            inferenceProvider: provider,
            tools: [makeExclusive("mlx-one"), makeExclusive("mlx-two")]
        )

        _ = try await agent.run(goal: "x")

        #expect(await gauge.peak == 1)
    }
}

/// A tool whose behaviour is a closure — lets a test coordinate executions.
private final class ClosureTool: AgentTool, @unchecked Sendable {
    let name: String
    let description = "closure"
    let parameters: [ToolParameter] = []
    var requiresExclusiveComputeOverride = false
    private let body: @Sendable () async -> String

    var requiresExclusiveCompute: Bool {
        requiresExclusiveComputeOverride
    }

    init(name: String, body: @escaping @Sendable () async -> String) {
        self.name = name
        self.body = body
    }

    func execute(input _: [String: String]) async throws -> ToolResult {
        await ToolResult(output: body())
    }
}
