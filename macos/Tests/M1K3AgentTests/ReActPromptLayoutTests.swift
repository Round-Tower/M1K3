//
//  ReActPromptLayoutTests.swift
//  M1K3AgentTests
//
//  The ReAct floor's stable-first layout (2026-09-14). Mini's agent prompt used
//  to open with the user's goal, so nothing at its front was the same from one
//  turn to the next and AFM's `prewarm(promptPrefix:)` had nothing to process
//  ahead of time. The layout now puts the parts that don't change for a given
//  tool palette first — the tools, the caller's standing rules, the format —
//  then what this turn brings, then the goal. These pin the order, the byte
//  parity between the head a prewarm processes and the live prompt, and the
//  head reaching the backend's end-of-turn warm.
//
//  Signed: Kev + claude-opus-5, 2026-09-14, Confidence 0.85 (red-first against
//  the goal-first layout; the timing win is measured on the installed app, not
//  here). Prior: Unknown
//

import M1K3Agent
import M1K3Inference
import Testing

private struct NamedTool: AgentTool {
    let name: String
    let description: String
    var parameters: [ToolParameter] {
        []
    }

    func execute(input _: [String: String]) async throws -> ToolResult {
        ToolResult(output: "ok")
    }
}

/// Records every prompt and every end-of-turn warm. `@unchecked Sendable`:
/// mutation is confined to the agent's sequential awaits within one test.
private final class RecordingProvider: InferenceProvider, PersonaCarrying, TurnWarmable, @unchecked Sendable {
    let name = "recording"
    let isAvailable = true
    let carriesStandingPersona: Bool
    private(set) var prompts: [String] = []
    private(set) var warmPrefixes: [String?] = []
    private var replies: [String]

    init(carriesPersona: Bool, replies: [String] = ["CONCLUSION: done"]) {
        carriesStandingPersona = carriesPersona
        self.replies = replies
    }

    func generate(prompt: String) async throws -> String {
        prompts.append(prompt)
        return replies.isEmpty ? "CONCLUSION: done" : replies.removeFirst()
    }

    func generateStreaming(prompt _: String) -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }

    func prepareForNextTurn(promptPrefix: String?) {
        warmPrefixes.append(promptPrefix)
    }
}

struct ReActPromptLayoutTests {
    private let tools: [any AgentTool] = [
        NamedTool(name: "web_search", description: "Search the web."),
        NamedTool(name: "datetime", description: "The time."),
    ]
    private let standing = "RULES:\n- Be kind."

    @Test("the head is the tool list, the standing rules, then the format — nothing from the turn")
    func headOrder() throws {
        let head = ReActPrompt.head(tools: tools, standing: standing)
        let toolList = try #require(head.range(of: "Available Tools:\ndatetime: The time.\nweb_search: Search the web."))
        let rules = try #require(head.range(of: standing))
        let format = try #require(head.range(of: "Use ReAct reasoning:"))
        #expect(head.hasPrefix("Available Tools:"))
        #expect(toolList.upperBound < rules.lowerBound)
        #expect(rules.upperBound < format.lowerBound)
        #expect(!head.contains("Your goal:"))
        #expect(!head.contains("Context:"))
        // The live prompt continues straight after it, so it ends on the blank line.
        #expect(head.hasSuffix("\"CONCLUSION:\"\n\n"))
    }

    @Test("without standing rules the head is the tool list then the format")
    func headWithoutStanding() {
        let head = ReActPrompt.head(tools: tools, standing: nil)
        #expect(head.hasPrefix("Available Tools:\ndatetime: The time.\nweb_search: Search the web.\n\nUse ReAct reasoning:"))
        #expect(!head.contains("RULES"))
    }

    @Test("the tail is the turn's context, then the goal, then the cue")
    func tailOrder() {
        #expect(
            ReActPrompt.tail(goal: "what's up?", context: "Right now: Monday.")
                == "Context:\nRight now: Monday.\n\nYour goal: what's up?\n\nBegin your analysis:"
        )
        #expect(ReActPrompt.tail(goal: "hi", context: nil) == "Your goal: hi\n\nBegin your analysis:")
    }

    @Test("the first prompt of a turn starts with exactly the head a prewarm would process")
    func firstPromptStartsWithHead() async throws {
        let provider = RecordingProvider(carriesPersona: true)
        let agent = LocalAgent(inferenceProvider: provider, tools: tools, maxIterations: 3)
        _ = try await agent.run(goal: "what's up?", context: "Right now: Monday.", standing: standing)
        let head = ReActPrompt.head(tools: tools, standing: standing)
        let prompt = try #require(provider.prompts.first)
        #expect(prompt.hasPrefix(head))
        #expect(prompt == head + ReActPrompt.tail(goal: "what's up?", context: "Right now: Monday.") + "\n\nThought 1:")
    }

    @Test("the goal comes after the rules and the context — last before the cue")
    func goalIsLast() async throws {
        let provider = RecordingProvider(carriesPersona: true)
        let agent = LocalAgent(inferenceProvider: provider, tools: tools, maxIterations: 3)
        _ = try await agent.run(goal: "what's up?", context: "KNOWLEDGE: none", standing: standing)
        let prompt = try #require(provider.prompts.first)
        let rules = try #require(prompt.range(of: standing))
        let context = try #require(prompt.range(of: "KNOWLEDGE: none"))
        let goal = try #require(prompt.range(of: "Your goal: what's up?"))
        #expect(rules.upperBound < context.lowerBound)
        #expect(context.upperBound < goal.lowerBound)
    }

    @Test("a later iteration keeps the same head, so it still shares the prefix")
    func laterIterationsKeepHead() async throws {
        let provider = RecordingProvider(carriesPersona: true, replies: ["ACTION: datetime()", "CONCLUSION: noon"])
        let agent = LocalAgent(inferenceProvider: provider, tools: tools, maxIterations: 3)
        _ = try await agent.run(goal: "what time is it?", context: nil, standing: standing)
        let head = ReActPrompt.head(tools: tools, standing: standing)
        #expect(provider.prompts.count == 2)
        #expect(provider.prompts.allSatisfy { $0.hasPrefix(head) })
    }

    @Test("the turn's end hands the backend the head, so the next turn's prewarm matches it")
    func warmReceivesHead() async throws {
        let provider = RecordingProvider(carriesPersona: true)
        let agent = LocalAgent(inferenceProvider: provider, tools: tools, maxIterations: 3)
        _ = try await agent.run(goal: "hi", context: nil, standing: standing)
        #expect(provider.warmPrefixes == [ReActPrompt.head(tools: tools, standing: standing)])
    }

    @Test("a backend without the persona gets it first, and its warm prefix includes it")
    func personaLeadsWhenNotCarried() async throws {
        let provider = RecordingProvider(carriesPersona: false)
        let agent = LocalAgent(inferenceProvider: provider, tools: tools, maxIterations: 3)
        _ = try await agent.run(goal: "hi", context: nil, standing: standing)
        let expected = M1K3Persona.systemPrompt + "\n\n" + ReActPrompt.head(tools: tools, standing: standing)
        #expect(provider.prompts.first?.hasPrefix(expected) == true)
        #expect(provider.warmPrefixes == [expected])
    }
}
