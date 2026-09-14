//
//  ReActTrailingActionTests.swift
//  M1K3AgentTests
//
//  Mini's tool calls were being thrown away (2026-09-14, read off the live
//  responder's debug trace): it opens every reply with "CONCLUSION:" — the rules
//  tell it to, twice — then decides it needs a tool and ends with the call:
//
//      CONCLUSION: That's a factual one, so I'll use lookup_fact to confirm.
//      ACTION: lookup_fact(founding of Cork)
//
//  8 of 10 live tool-use turns had that shape. The loop concluded on the marker
//  and stripped the ACTION line as scaffolding, so the user got "I'll use
//  lookup_fact to confirm" and nothing after it: tool-use 0/30. These pin the
//  fix: a conclusion that ENDS in a call to an offered tool runs the tool, and
//  whatever streamed live before the call is followed by the real answer. Once
//  tools ran, a real web page overflowed Mini's 4,096-token window on the next
//  iteration (read off the installed app: 4,209 tokens), so the ReAct floor can
//  cap how much of an observation rides the next prompt.
//
//  Signed: Kev + claude-opus-5, 2026-09-14, Confidence 0.85, Prior: Unknown
//

import Foundation
@testable import M1K3Agent
import M1K3Inference
import Testing

/// Streams each scripted reply as one chunk, and answers `generate` from the
/// same script (the cap-reached synthesis is a plain generate).
private final class StreamingScriptedProvider: InferenceProvider, @unchecked Sendable {
    let name = "streaming-scripted"
    let isAvailable = true
    private let lock = NSLock()
    private var replies: [String]
    private(set) var prompts: [String] = []

    init(_ replies: [String]) {
        self.replies = replies
    }

    private func next(_ prompt: String) -> String {
        lock.withLock {
            prompts.append(prompt)
            return replies.isEmpty ? "CONCLUSION: (fallback)" : replies.removeFirst()
        }
    }

    func generate(prompt: String) async throws -> String {
        next(prompt)
    }

    func generateStreaming(prompt: String) -> AsyncStream<String> {
        let reply = next(prompt)
        return AsyncStream { continuation in
            continuation.yield(reply)
            continuation.finish()
        }
    }
}

/// Counts executions, so a repeated call can be told apart from a new one.
private final class CountedTool: AgentTool, @unchecked Sendable {
    let name = "search"
    let description = "searches"
    let parameters = [ToolParameter(name: "query", description: "the query")]
    private(set) var runs = 0
    func execute(input _: [String: String]) async throws -> ToolResult {
        runs += 1
        return ToolResult(output: "Founded in the 6th century")
    }
}

/// Collects what streamed live to the user.
private final class LiveText: @unchecked Sendable {
    private let lock = NSLock()
    private var parts: [String] = []
    var text: String {
        lock.withLock { parts.joined() }
    }

    func append(_ piece: String) {
        lock.withLock { parts.append(piece) }
    }
}

struct ReActTrailingActionTests {
    @Test("a conclusion that ends in a call to an offered tool runs the tool")
    func trailingActionRunsTheTool() async throws {
        let provider = ScriptedProvider([
            "CONCLUSION: That's a factual one, so I'll use search to confirm.\nACTION: search(founding of Cork)",
            "CONCLUSION: Cork was founded in the 6th century.",
        ])
        let agent = LocalAgent(inferenceProvider: provider, tools: [EchoTool(response: "Founded in the 6th century")])
        let result = try await agent.run(goal: "When was Cork founded?")
        #expect(result.conclusion == "Cork was founded in the 6th century.")
        #expect(result.toolsUsed == ["search"])
        #expect(result.iterations == 2)
        #expect(result.reasoningTrace.first?.action == "search(founding of Cork)")
        #expect(provider.prompts.last?.contains("Observation: Founded in the 6th century") == true)
    }

    @Test("a trailing call to a tool that wasn't offered still concludes, call stripped")
    func unofferedToolConcludes() async throws {
        let provider = ScriptedProvider(["CONCLUSION: It's Paris.\nACTION: teleport(Paris)"])
        let agent = LocalAgent(inferenceProvider: provider, tools: [EchoTool(response: "unused")])
        let result = try await agent.run(goal: "Capital of France?")
        #expect(result.conclusion == "It's Paris.")
        #expect(result.toolsUsed.isEmpty)
        #expect(result.iterations == 1)
    }

    @Test("an ACTION mentioned mid-sentence is prose, not a call")
    func midLineActionIsNotACall() async throws {
        let answer = "In the old format you'd write ACTION: search(x) — but the answer is 42."
        let provider = ScriptedProvider(["CONCLUSION: \(answer)"])
        let agent = LocalAgent(inferenceProvider: provider, tools: [EchoTool(response: "unused")])
        let result = try await agent.run(goal: "What's the answer?")
        #expect(result.conclusion == answer)
        #expect(result.toolsUsed.isEmpty)
    }

    @Test("a trailing call it already made concludes on the answer instead of looping")
    func repeatedTrailingActionConcludes() async throws {
        let tool = CountedTool()
        let provider = ScriptedProvider([
            "ACTION: search(Cork)",
            "CONCLUSION: Cork was founded in the 6th century.\nACTION: search(Cork)",
        ])
        let agent = LocalAgent(inferenceProvider: provider, tools: [tool])
        let result = try await agent.run(goal: "When was Cork founded?")
        #expect(result.conclusion == "Cork was founded in the 6th century.")
        #expect(tool.runs == 1)
        #expect(result.iterations == 2)
    }

    @Test("what streamed before the call is followed by the answer, a paragraph apart")
    func streamedPreambleThenAnswer() async throws {
        let provider = StreamingScriptedProvider([
            "CONCLUSION: That's a factual one, so I'll use search to confirm.\nACTION: search(Cork)",
            "CONCLUSION: Cork was founded in the 6th century.",
        ])
        let live = LiveText()
        let agent = LocalAgent(inferenceProvider: provider, tools: [EchoTool(response: "6th century")])
        let result = try await agent.run(goal: "When was Cork founded?", onConclusionToken: { live.append($0) })
        #expect(result.toolsUsed == ["search"])
        #expect(live.text == "That's a factual one, so I'll use search to confirm.\n\nCork was founded in the 6th century.")
    }

    @Test("after a streamed preamble, an unmarked final answer still reaches the stream")
    func streamedPreambleThenImplicitAnswer() async throws {
        let provider = StreamingScriptedProvider([
            "CONCLUSION: Let me check.\nACTION: search(Cork)",
            "Cork was founded in the 6th century.",
        ])
        let live = LiveText()
        let agent = LocalAgent(
            inferenceProvider: provider, tools: [EchoTool(response: "6th century")],
            concludesOnUnstructuredThought: true
        )
        let result = try await agent.run(goal: "When was Cork founded?", onConclusionToken: { live.append($0) })
        #expect(result.conclusion == "Cork was founded in the 6th century.")
        #expect(live.text == "Let me check.\n\nCork was founded in the 6th century.")
    }

    @Test("after a streamed preamble, the cap's synthesised answer still reaches the stream")
    func streamedPreambleThenSynthesis() async throws {
        let provider = StreamingScriptedProvider([
            "CONCLUSION: Let me check.\nACTION: search(Cork)",
            "Cork was founded in the 6th century.", // the cap's plain-generate synthesis
        ])
        let live = LiveText()
        let agent = LocalAgent(
            inferenceProvider: provider, tools: [EchoTool(response: "6th century")], maxIterations: 1
        )
        let result = try await agent.run(goal: "When was Cork founded?", onConclusionToken: { live.append($0) })
        #expect(result.conclusion == "Cork was founded in the 6th century.")
        #expect(live.text == "Let me check.\n\nCork was founded in the 6th century.")
    }

    @Test("an observation longer than the limit reaches the next prompt cut; the trace keeps it whole")
    func observationCappedInPrompt() async throws {
        let long = String(repeating: "lima ", count: 100) // 500 chars
        let provider = ScriptedProvider(["ACTION: search(Peru)", "CONCLUSION: Lima."])
        let agent = LocalAgent(
            inferenceProvider: provider, tools: [EchoTool(response: long)], observationCharLimit: 60
        )
        let result = try await agent.run(goal: "Capital of Peru?")
        let second = try #require(provider.prompts.last)
        #expect(second.contains("Observation: " + String(long.prefix(60)) + "…"))
        #expect(!second.contains(long))
        #expect(result.reasoningTrace.first?.observation == long)
    }

    @Test("with no limit, the observation reaches the next prompt whole, as always")
    func observationUncappedByDefault() async throws {
        let long = String(repeating: "lima ", count: 100)
        let provider = ScriptedProvider(["ACTION: search(Peru)", "CONCLUSION: Lima."])
        let agent = LocalAgent(inferenceProvider: provider, tools: [EchoTool(response: long)])
        _ = try await agent.run(goal: "Capital of Peru?")
        #expect(provider.prompts.last?.contains("Observation: " + long) == true)
    }

    @Test("nothing streamed before: a conclusion streams exactly as it always did")
    func plainConclusionUnchanged() async throws {
        let provider = StreamingScriptedProvider(["CONCLUSION: It's Paris."])
        let live = LiveText()
        let agent = LocalAgent(inferenceProvider: provider, tools: [])
        _ = try await agent.run(goal: "Capital of France?", onConclusionToken: { live.append($0) })
        #expect(live.text == "It's Paris.")
    }
}
