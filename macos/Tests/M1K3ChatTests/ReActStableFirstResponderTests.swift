//
//  ReActStableFirstResponderTests.swift
//  M1K3ChatTests
//
//  The responder's half of the ReAct floor's stable-first layout (2026-09-14):
//  on a ReAct turn the RULES leave the per-turn grounding and ride the loop's
//  stable head, and `reactPromptPrefix(tools:)` — what the Mini launch prewarm
//  processes — is byte-for-byte how the live turn's prompt begins. A prefix
//  that drifts by one character from the live prompt silently buys nothing,
//  so the pin is on the assembled prompt, not on the parts.
//
//  Signed: Kev + claude-opus-5, 2026-09-14, Confidence 0.85, Prior: Unknown
//

import Foundation
import M1K3Agent
@testable import M1K3Chat
import M1K3Inference
import M1K3Knowledge
import Synchronization
import Testing

private struct PaletteTool: AgentTool {
    let name: String
    let description: String
    var parameters: [ToolParameter] {
        [ToolParameter(name: "query", description: "the input")]
    }

    func execute(input _: [String: String]) async throws -> ToolResult {
        ToolResult(output: "ok")
    }
}

/// Carries the persona and speaks ReAct (no native tool calls) — the Mini shape.
private final class MiniShapedProvider: InferenceProvider, PersonaCarrying, Sendable {
    let name = "mini-shaped"
    let isAvailable = true
    let carriesStandingPersona = true
    private let seen = Mutex<[String]>([])
    var prompts: [String] {
        seen.withLock { $0 }
    }

    func generate(prompt: String) async throws -> String {
        seen.withLock { $0.append(prompt) }
        return "CONCLUSION: hi there"
    }

    func generateStreaming(prompt: String) -> AsyncStream<String> {
        seen.withLock { $0.append(prompt) }
        return AsyncStream { continuation in
            continuation.yield("CONCLUSION: hi there")
            continuation.finish()
        }
    }
}

struct ReActStableFirstResponderTests {
    private static let tools: [any AgentTool] = [
        PaletteTool(name: "web_search", description: "Search the web for current information."),
        PaletteTool(name: "search_knowledge", description: "Search stored knowledge."),
        PaletteTool(name: "datetime", description: "The current date and time."),
    ]

    private static func firstPrompt(for question: String) async throws -> String {
        let provider = MiniShapedProvider()
        let responder = try AgentRAGResponder(
            store: KnowledgeStore(), embedder: HashingEmbeddingService(), provider: provider,
            tools: tools, maxIterations: 3
        )
        for await _ in try await responder.answerStreaming(question).stream {}
        return try #require(provider.prompts.first)
    }

    @Test("the live ReAct turn begins with exactly the prefix the Mini prewarm processes")
    func livePromptStartsWithThePrewarmPrefix() async throws {
        let prompt = try await Self.firstPrompt(for: "what's the weather in Cork?")
        let prefix = AgentRAGResponder.reactPromptPrefix(tools: Self.tools)
        #expect(prompt.hasPrefix(prefix))
        // And the prefix holds the standing rules, not only the tool list.
        #expect(prefix.contains("RULES:"))
        #expect(prefix.contains(AgentRAGResponder.currentWorldRouting(notes: .below)))
    }

    @Test("on the live ReAct turn the question comes last, after the turn's context and the rules")
    func questionComesLast() async throws {
        let prompt = try await Self.firstPrompt(for: "what's the weather in Cork?")
        let rules = try #require(prompt.range(of: "RULES:"))
        let now = try #require(prompt.range(of: "Right now"))
        let goal = try #require(prompt.range(of: "Your goal: what's the weather in Cork?"))
        #expect(rules.upperBound < now.lowerBound)
        #expect(now.upperBound < goal.lowerBound)
        #expect(prompt.components(separatedBy: "RULES:").count == 2, "the rules ride once, in the head")
    }

    @Test("the ReAct parts are the full grounding, split — the same words, the rules moved")
    func reactPartsAreTheGroundingSplit() {
        let names = Set(Self.tools.map(\.name))
        let parts = AgentRAGResponder.reactParts(chunks: [], toolNames: names)
        #expect(parts.context + "\n\n" + parts.standing == AgentRAGResponder.grounding(chunks: [], toolNames: names))
        #expect(!parts.context.contains("RULES:"))
        #expect(parts.standing.hasPrefix("RULES:"))
    }

    @Test("the ReAct rules point at notes below them; the native rules keep \"above\"")
    func notesWordingFollowsTheLayout() {
        let names: Set = ["web_search"]
        let react = AgentRAGResponder.reactParts(chunks: [], toolNames: names).standing
        let native = AgentRAGResponder.grounding(chunks: [], toolNames: names, style: .native)
        #expect(react.contains("even when notes appear below"))
        #expect(!react.contains("injected above"))
        #expect(native.contains("even when notes were injected above"))
    }
}
