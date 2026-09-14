//
//  ReActPreambleFallbackTests.swift
//  M1K3ChatTests
//
//  Since a ReAct conclusion that ends in a tool call now RUNS the tool
//  (2026-09-14), a turn can stream a preamble — "Let me check." — and only
//  then reach its answer. The responder used to fall back to a grounded answer
//  only when NOTHING had streamed, so a turn that streamed a preamble and then
//  concluded empty would stop at "Let me check." (review of 06c2fc11). And the
//  fallback forwarded the provider's raw chunks, which from Apple Foundation
//  Models are CUMULATIVE snapshots: after a preamble, the consumer's fold would
//  read each snapshot as new text and repeat it. These pin both.
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

private struct LookupTool: AgentTool {
    let name = "lookup"
    let description = "Look something up."
    var parameters: [ToolParameter] {
        [ToolParameter(name: "query", description: "the input")]
    }

    func execute(input _: [String: String]) async throws -> ToolResult {
        ToolResult(output: "Cork was founded in the 6th century.")
    }
}

/// Carries the persona and speaks ReAct (the Mini shape). Each call streams the
/// next scripted entry chunk by chunk — AFM-style cumulative snapshots where
/// the entry holds several.
private final class SnapshotScriptedProvider: InferenceProvider, PersonaCarrying, Sendable {
    let name = "snapshot-scripted"
    let isAvailable = true
    let carriesStandingPersona = true
    private let script: Mutex<[[String]]>

    init(_ script: [[String]]) {
        self.script = Mutex(script)
    }

    private func next() -> [String] {
        script.withLock { $0.isEmpty ? ["CONCLUSION: (fallback)"] : $0.removeFirst() }
    }

    func generate(prompt _: String) async throws -> String {
        next().last ?? ""
    }

    func generateStreaming(prompt _: String) -> AsyncStream<String> {
        let chunks = next()
        return AsyncStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}

struct ReActPreambleFallbackTests {
    /// What the chat shows: every chunk folded the way ChatSession folds it.
    private static func shown(_ script: [[String]]) async throws -> String {
        let responder = try AgentRAGResponder(
            store: KnowledgeStore(), embedder: HashingEmbeddingService(),
            provider: SnapshotScriptedProvider(script), tools: [LookupTool()], maxIterations: 3
        )
        var text = ""
        for await chunk in try await responder.answerStreaming("When was Cork founded?").stream {
            text = StreamFold.fold(current: text, chunk: chunk)
        }
        return text
    }

    @Test("a preamble, a tool call, then an empty conclusion: the fallback still answers, a paragraph on")
    func emptyConclusionAfterPreambleFallsBack() async throws {
        let text = try await Self.shown([
            ["CONCLUSION: Let me check.\nACTION: lookup(Cork)"],
            ["CONCLUSION:"],
            ["Cork", "Cork was founded", "Cork was founded in the 6th century."], // the fallback, as snapshots
        ])
        #expect(text == "Let me check.\n\nCork was founded in the 6th century.")
    }

    @Test("with nothing streamed first, the fallback's snapshots still read once")
    func fallbackSnapshotsReadOnce() async throws {
        let text = try await Self.shown([
            ["CONCLUSION:"],
            ["Cork", "Cork was founded", "Cork was founded in the 6th century."],
        ])
        #expect(text == "Cork was founded in the 6th century.")
    }

    @Test("a preamble, a tool call, then a real conclusion: shown once, a paragraph apart")
    func preambleThenAnswer() async throws {
        let text = try await Self.shown([
            ["CONCLUSION: Let me check.\nACTION: lookup(Cork)"],
            ["CONCLUSION: Cork was founded in the 6th century."],
        ])
        #expect(text == "Let me check.\n\nCork was founded in the 6th century.")
    }
}
