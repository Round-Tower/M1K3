//
//  M1K3ModelExecutorTests.swift
//  M1K3AgentTests
//
//  Pins the WWDC26-bridge executor (ADR 0001): the real ThinkStreamGate routes a
//  streamed turn into the channel — reasoning aside, a CLEAN answer out, tool calls
//  surfaced — with NO double-emit of the buffered answer.
//

@testable import M1K3Agent
import M1K3Inference
import M1K3LanguageModel
import Testing

/// A `ToolTurnSession` that streams a fixed token list (faithfully, one `onToken`
/// per chunk — including tags split across chunks) then returns a scripted outcome.
/// Exercises the gate exactly as a real provider would.
private final class ScriptedTokenSession: ToolTurnSession, @unchecked Sendable {
    let tokens: [String]
    let outcome: ToolTurn
    private(set) var sentMessages: [[ToolMessage]] = []

    init(tokens: [String], outcome: ToolTurn) {
        self.tokens = tokens
        self.outcome = outcome
    }

    func send(
        _ messages: [ToolMessage],
        onToken: @escaping @Sendable (String) -> Void
    ) async throws -> ToolTurn {
        sentMessages.append(messages)
        for token in tokens {
            onToken(token)
        }
        return outcome
    }

    func finish() async {}
}

struct M1K3ModelExecutorTests {
    @Test("reasoning is routed aside; the answer is clean (no <think> leak)")
    func reasoningAndAnswerSplit() async throws {
        let session = ScriptedTokenSession(
            tokens: ["<th", "ink>", "weigh", "ing</think>", "You're", " in Cork."],
            outcome: .text("ignored — the live stream is authoritative")
        )
        let channel = GenerationChannel()
        try await M1K3ModelExecutor(session: session).respond(to: "where am i", into: channel)

        #expect(channel.answer == "You're in Cork.")
        #expect(channel.answer.contains("<think>") == false)
        #expect(channel.reasoning.contains("<think>"))
        #expect(channel.reasoning.contains("weighing"))
    }

    @Test("THE TRAP: the buffered answer is emitted exactly once, not doubled")
    func answerNotDoubled() async throws {
        let session = ScriptedTokenSession(
            tokens: ["<think>x</think>", "The answer."],
            outcome: .text("The answer.")
        )
        let channel = GenerationChannel()
        try await M1K3ModelExecutor(session: session).respond(to: "q", into: channel)
        #expect(channel.answer == "The answer.")
    }

    @Test("a rejected tool call reports its streamed prose like a text turn, once (#418)")
    func rejectedCallReportsProse() async throws {
        let session = ScriptedTokenSession(
            tokens: ["<think>pick a tool</think>", "I couldn't form that call."],
            outcome: .rejectedToolCalls(reason: "invalid_arguments (search)", text: "I couldn't form that call.")
        )
        let channel = GenerationChannel()
        try await M1K3ModelExecutor(session: session).respond(to: "q", into: channel)
        #expect(channel.answer == "I couldn't form that call.")
        #expect(channel.toolCalls.isEmpty)
    }

    @Test("a turn that never thinks → all answer, no reasoning")
    func noThinkAllAnswer() async throws {
        let session = ScriptedTokenSession(
            tokens: ["Hello", ", ", "world."],
            outcome: .text("Hello, world.")
        )
        let channel = GenerationChannel()
        try await M1K3ModelExecutor(session: session).respond(to: "hi", into: channel)
        #expect(channel.answer == "Hello, world.")
        #expect(channel.reasoning.isEmpty)
    }

    @Test("a close tag split across tokens is still caught")
    func splitCloseTag() async throws {
        let session = ScriptedTokenSession(
            tokens: ["<think>mulling</thi", "nk>", "Done."],
            outcome: .text("Done.")
        )
        let channel = GenerationChannel()
        try await M1K3ModelExecutor(session: session).respond(to: "q", into: channel)
        #expect(channel.answer == "Done.")
        #expect(channel.answer.contains("</thi") == false)
        #expect(channel.reasoning.contains("mulling"))
    }

    @Test("a tool-calls outcome is surfaced as channel events, with no answer text")
    func toolCallsRouted() async throws {
        let calls = [
            ParsedToolCall(name: "search_knowledge", arguments: ["query": .string("cork")]),
            ParsedToolCall(name: "lookup_fact", arguments: ["topic": .string("sweet track")]),
        ]
        let session = ScriptedTokenSession(tokens: [], outcome: .toolCalls(calls))
        let channel = GenerationChannel()
        try await M1K3ModelExecutor(session: session).respond(to: "q", into: channel)

        #expect(channel.answer.isEmpty)
        #expect(channel.toolCalls.count == 2)
        #expect(channel.toolCalls.first?.name == "search_knowledge")
        #expect(channel.toolCalls.first?.arguments["query"] == "cork")
        #expect(channel.toolCalls.last?.name == "lookup_fact")
    }

    @Test("the system prompt is prepended to the turn transcript")
    func systemPromptPrepended() async throws {
        let session = ScriptedTokenSession(tokens: ["ok"], outcome: .text("ok"))
        let channel = GenerationChannel()
        let executor = M1K3ModelExecutor(session: session, systemPrompt: "You are M1K3.")
        try await executor.respond(to: "hi", into: channel)

        let transcript = try #require(session.sentMessages.first)
        #expect(transcript.first == .system("You are M1K3."))
        #expect(transcript.last == .user("hi"))
        #expect(channel.inputTokenCount > 0)
    }
}
