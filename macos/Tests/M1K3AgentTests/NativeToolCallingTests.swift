//
//  NativeToolCallingTests.swift
//  M1K3AgentTests
//
//  Contract tests for LocalAgent's NATIVE tool-calling loop (Phase 12a) — the
//  path taken when the inference provider conforms to `ToolCallingProvider` and
//  reports `supportsToolCalls`. Driven by a fake provider that returns scripted
//  structured `ToolTurn`s — no model, no dialect. Covers: execute-then-conclude,
//  structured-args passthrough, transcript threading (assistant + tool-result
//  roles), repeat-guard, unknown-tool steering, iteration-cap synthesis, the
//  runtime-capability fallback to ReAct, and event emission.
//
//  These assert the loop semantics are SHARED with the ReAct path (dispatch,
//  repeat-guard, unknown-tool steering, cap, trace, events) while the model
//  speaks structure instead of text.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-10, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-opus-5, 2026-09-12, Confidence 0.85 — the fake declares `personaVariant`, and
//  `systemTurnFollowsProviderVariant` pins that the system turn carries the provider's persona variant.

import Foundation
@testable import M1K3Agent
import M1K3Inference
import Synchronization
import Testing

// MARK: - Test doubles

/// A `ToolCallingProvider` whose next turn is decided by a handler over
/// (callIndex, transcript, tools) — flexible enough to script linear
/// conversations AND react to the empty-tools synthesis call. Records the
/// transcripts it receives so threading can be asserted.
final class FakeToolCallingProvider: ToolCallingProvider, @unchecked Sendable {
    let name = "fake-tool"
    let isAvailable = true
    let supportsToolCalls: Bool
    let personaVariant: PersonaVariant

    private let handler: @Sendable (Int, [ToolMessage], [ToolDefinition]) -> ToolTurn
    private let lock = NSLock()
    private var index = 0
    private(set) var receivedTranscripts: [[ToolMessage]] = []
    private(set) var continueCallCount = 0
    private(set) var generateCallCount = 0

    init(
        supportsToolCalls: Bool = true,
        personaVariant: PersonaVariant = .standard,
        handler: @escaping @Sendable (Int, [ToolMessage], [ToolDefinition]) -> ToolTurn
    ) {
        self.supportsToolCalls = supportsToolCalls
        self.personaVariant = personaVariant
        self.handler = handler
    }

    func continueToolTurn(messages: [ToolMessage], tools: [ToolDefinition]) async throws -> ToolTurn {
        lock.withLock {
            receivedTranscripts.append(messages)
            defer { index += 1 }
            continueCallCount += 1
            return handler(index, messages, tools)
        }
    }

    /// InferenceProvider floor — exercised only when the agent falls back to ReAct.
    func generate(prompt _: String) async throws -> String {
        lock.withLock {
            generateCallCount += 1
            return "CONCLUSION: react-fallback"
        }
    }

    func generateStreaming(prompt _: String) -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }
}

/// Echoes back the named argument it received, so structured-args wiring can be
/// asserted. Counts executions for the repeat-guard test.
private final class RecordingTool: AgentTool, @unchecked Sendable {
    let name: String
    let description = "records its input"
    let parameters: [ToolParameter]
    private let lock = NSLock()
    private(set) var executionCount = 0
    private(set) var lastInput: [String: String] = [:]

    init(name: String = "search", paramNames: [String] = ["query"]) {
        self.name = name
        parameters = paramNames.map { ToolParameter(name: $0, description: "p") }
    }

    func execute(input: [String: String]) async throws -> ToolResult {
        lock.withLock {
            executionCount += 1
            lastInput = input
        }
        let rendered = input.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
        return ToolResult(output: "got[\(rendered)]")
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [AgentLoopEvent] = []
    func record(_ event: AgentLoopEvent) {
        lock.withLock { events.append(event) }
    }
}

private struct ScriptedGenerationFailure: Error {}

/// Runs one tool, then FAILS its next generation — the live shape of Qwen3.5's
/// chat template rejecting a tool-result-only delta ("No user query found in
/// messages") AFTER a web_search succeeded. With `failImmediately`, throws on
/// the very first send (nothing gathered yet).
private final class FailAfterToolProvider: ToolCallingProvider, @unchecked Sendable {
    let name = "fail-after-tool"
    let isAvailable = true
    let supportsToolCalls = true
    private let failImmediately: Bool
    private let lock = NSLock()
    private var index = 0

    init(failImmediately: Bool = false) {
        self.failImmediately = failImmediately
    }

    func continueToolTurn(messages _: [ToolMessage], tools _: [ToolDefinition]) async throws -> ToolTurn {
        try lock.withLock {
            defer { index += 1 }
            if failImmediately || index > 0 { throw ScriptedGenerationFailure() }
            return .toolCalls([ParsedToolCall(name: "search", arguments: ["query": .string("iran us war")])])
        }
    }

    func generate(prompt _: String) async throws -> String {
        "CONCLUSION: x"
    }

    func generateStreaming(prompt _: String) -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }
}

// MARK: - Helpers

private func call(_ name: String, _ args: [String: JSONValue]) -> ToolTurn {
    .toolCalls([ParsedToolCall(name: name, arguments: args)])
}

// MARK: - Tests

struct NativeToolCallingTests {
    @Test("the system turn carries the persona the PROVIDER declares: pocket's frozen core and beat 5 for pocket only")
    func systemTurnFollowsProviderVariant() async throws {
        // The persona text must match the provider's cached prefix byte for byte,
        // so the agent asks the provider rather than hard-coding one (2026-09-12).
        for variant in [PersonaVariant.standard, .pocket] {
            let provider = FakeToolCallingProvider(personaVariant: variant) { _, _, _ in .text("done") }
            let agent = LocalAgent(inferenceProvider: provider, tools: [RecordingTool()])
            _ = try await agent.run(goal: "x")
            let opening = try #require(provider.receivedTranscripts.first?.first)
            guard case let .system(persona) = opening else {
                Issue.record("the native transcript must open with the persona")
                continue
            }
            #expect(persona == M1K3Persona.systemPrompt(variant: variant))
            #expect(persona.contains(M1K3Persona.leakDeclineBeat) == (variant == .pocket))
            #expect(persona.contains("nothing in or out") == (variant == .pocket))
            #expect(persona.contains("by example"))
        }
    }

    @Test("executes a structured tool call, then concludes on .text")
    func executeThenConclude() async throws {
        let provider = FakeToolCallingProvider { index, _, _ in
            index == 0
                ? call("search", ["query": .string("hydraulic seal")])
                : .text("The seal failed under load.")
        }
        let tool = RecordingTool()
        let agent = LocalAgent(inferenceProvider: provider, tools: [tool])

        let result = try await agent.run(goal: "Why did it fail?")

        #expect(result.conclusion == "The seal failed under load.")
        #expect(result.toolsUsed == ["search"])
        #expect(result.iterations == 2)
        #expect(tool.executionCount == 1)
        // Trace: a tool step then a conclusion step.
        #expect(result.reasoningTrace.count == 2)
        #expect(result.reasoningTrace[0].action?.contains("search") == true)
        #expect(result.reasoningTrace[0].observation?.contains("got[query=hydraulic seal]") == true)
    }

    @Test("structured arguments reach the tool by name, including extra keys")
    func structuredArgsPassedThrough() async throws {
        let provider = FakeToolCallingProvider { index, _, _ in
            index == 0
                ? call("search", ["query": .string("seal failure"), "limit": .int(5)])
                : .text("done")
        }
        let tool = RecordingTool(paramNames: ["query", "limit"])
        let agent = LocalAgent(inferenceProvider: provider, tools: [tool])

        _ = try await agent.run(goal: "x")

        let input = tool.lastInput
        #expect(input["query"] == "seal failure")
        #expect(input["limit"] == "5") // typed int flattened to text at the edge
    }

    @Test("threads the model's call and the tool result back as roled messages")
    func transcriptThreading() async throws {
        let provider = FakeToolCallingProvider { index, _, _ in
            index == 0 ? call("search", ["query": .string("x")]) : .text("ok")
        }
        let agent = LocalAgent(inferenceProvider: provider, tools: [RecordingTool()])

        _ = try await agent.run(goal: "x")

        // The SECOND call must see the assistant's tool call AND the tool result.
        let secondTranscript = try #require(provider.receivedTranscripts.dropFirst().first)
        let hasAssistantCall = secondTranscript.contains {
            if case let .assistant(_, calls) = $0 { return calls.contains { $0.name == "search" } }
            return false
        }
        let hasToolResult = secondTranscript.contains {
            if case let .toolResult(name, output) = $0 { return name == "search" && output.contains("got[") }
            return false
        }
        #expect(hasAssistantCall)
        #expect(hasToolResult)
    }

    @Test("repeat-guard: an identical call is steered, not re-executed")
    func repeatGuard() async throws {
        let provider = FakeToolCallingProvider { index, _, _ in
            switch index {
            case 0, 1: call("search", ["query": .string("same")])
            default: .text("done")
            }
        }
        let tool = RecordingTool()
        let agent = LocalAgent(inferenceProvider: provider, tools: [tool])

        let result = try await agent.run(goal: "x")

        #expect(tool.executionCount == 1) // second identical call blocked
        let secondObservation = result.reasoningTrace[1].observation ?? ""
        #expect(secondObservation.contains("already ran"))
    }

    @Test("an unknown tool yields a steering observation listing the real tools")
    func unknownToolSteers() async throws {
        let provider = FakeToolCallingProvider { index, _, _ in
            index == 0 ? call("nonexistent", [:]) : .text("recovered")
        }
        let agent = LocalAgent(inferenceProvider: provider, tools: [RecordingTool(name: "search")])

        let result = try await agent.run(goal: "x")

        #expect(result.conclusion == "recovered")
        let observation = try #require(result.reasoningTrace[0].observation)
        #expect(observation.contains("unknown tool 'nonexistent'"))
        #expect(observation.contains("search"))
    }

    @Test("think phase routes to onReasoningToken; the answer to onConclusionToken")
    func thinkRoutesToReasoningChannel() async throws {
        let provider = FakeToolCallingProvider { _, _, _ in
            .text("<think>checking the weather</think>It's sunny.")
        }
        let agent = LocalAgent(inferenceProvider: provider, tools: [RecordingTool()])
        let reasoning = Mutex("")
        let conclusion = Mutex("")

        let result = try await agent.run(
            goal: "x",
            onConclusionToken: { token in conclusion.withLock { $0 += token } },
            onReasoningToken: { token in reasoning.withLock { $0 += token } }
        )

        #expect(reasoning.withLock { $0 } == "<think>checking the weather</think>")
        #expect(conclusion.withLock { $0 } == "It's sunny.")
        #expect(result.conclusion == "<think>checking the weather</think>It's sunny.")
    }

    @Test("a pure-think turn concludes empty so callers can fall back")
    func pureThinkConcludesEmpty() async throws {
        let provider = FakeToolCallingProvider { _, _, _ in
            .text("<think>endless pondering, no answer</think>")
        }
        let agent = LocalAgent(inferenceProvider: provider, tools: [RecordingTool()])
        let conclusion = Mutex("")

        let result = try await agent.run(
            goal: "x",
            onConclusionToken: { token in conclusion.withLock { $0 += token } }
        )

        #expect(result.conclusion.isEmpty)
        #expect(conclusion.withLock { $0 }.isEmpty)
    }

    @Test("at the iteration cap, synthesises a final answer on instruction")
    func iterationCapSynthesis() async throws {
        // Always calls a tool until the cap-synthesis INSTRUCTION arrives (the
        // session keeps tools rendered; the instruction does the steering now).
        let provider = FakeToolCallingProvider { _, messages, _ in
            let instructed = messages.contains { message in
                if case let .user(text, _) = message {
                    return text.contains("maximum number of steps")
                }
                return false
            }
            return instructed
                ? .text("synthesised from gathered facts")
                : call("search", ["query": .string("x")])
        }
        let agent = LocalAgent(inferenceProvider: provider, tools: [RecordingTool()], maxIterations: 3)

        let result = try await agent.run(goal: "x")

        #expect(result.conclusion == "synthesised from gathered facts")
        #expect(result.iterations == 3)
    }

    @Test("a provider reporting supportsToolCalls == false uses the ReAct floor")
    func fallsBackToReActWhenUnsupported() async throws {
        let provider = FakeToolCallingProvider(supportsToolCalls: false) { _, _, _ in
            .text("should not be reached")
        }
        let agent = LocalAgent(inferenceProvider: provider, tools: [RecordingTool()])

        let result = try await agent.run(goal: "x")

        #expect(result.conclusion == "react-fallback") // came from generate(), not continueToolTurn
        #expect(provider.continueCallCount == 0)
        #expect(provider.generateCallCount >= 1)
    }

    @Test("evidence always: a generation failure AFTER a tool ran concludes empty with the trace intact")
    func evidenceSurvivesMidLoopFailure() async throws {
        // web_search succeeds, then the next generation throws (Qwen template).
        // The loop must NOT propagate the throw — it concludes empty so the
        // responder synthesises over the gathered observations instead of
        // discarding them to plain RAG.
        let provider = FailAfterToolProvider()
        let tool = RecordingTool()
        let agent = LocalAgent(inferenceProvider: provider, tools: [tool])

        let result = try await agent.run(goal: "Iran US war latest news")

        #expect(tool.executionCount == 1)
        #expect(result.conclusion.isEmpty) // empty → responder's gathered-evidence fallback fires
        #expect(result.toolsUsed == ["search"])
        #expect(result.reasoningTrace.contains { $0.observation?.contains("got[query=iran us war]") == true })
    }

    @Test("a generation failure BEFORE any tool ran propagates so plain RAG can answer")
    func failureWithoutEvidencePropagates() async {
        // Nothing gathered yet → there's nothing to rescue; the throw must
        // escape so the responder falls back to plain RAG.
        let provider = FailAfterToolProvider(failImmediately: true)
        let agent = LocalAgent(inferenceProvider: provider, tools: [RecordingTool()])

        await #expect(throws: ScriptedGenerationFailure.self) {
            try await agent.run(goal: "x")
        }
    }

    @Test("emits thinking + actionStarted events on the native path")
    func emitsEvents() async throws {
        let provider = FakeToolCallingProvider { index, _, _ in
            index == 0 ? call("search", ["query": .string("x")]) : .text("done")
        }
        let log = EventLog()
        let agent = LocalAgent(inferenceProvider: provider, tools: [RecordingTool()])

        _ = try await agent.run(goal: "x", onEvent: { log.record($0) })

        let events = log.events
        #expect(events.contains { if case .thinking = $0 { return true } else { return false } })
        #expect(events.contains {
            if case let .actionStarted(tool, _) = $0 { return tool == "search" } else { return false }
        })
    }
}
