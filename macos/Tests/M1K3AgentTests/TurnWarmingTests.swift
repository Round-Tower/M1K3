//
//  TurnWarmingTests.swift
//  M1K3AgentTests
//
//  The AFM prewarm re-arm cadence: once per TURN, never per generate call.
//  Mini's ReAct floor makes several rapid provider calls per user turn
//  (iterations + the conclusion synthesis), and a per-call re-arm interleaves
//  daemon round-trips between them — structurally the logged AFM rate-collapse
//  shape (pkill-poisons-afm-daemon, 2026-08-03: it is RATE, not force-quit).
//  So the re-arm rides a capability seam called exactly once when the agent
//  turn concludes.
//
//  Signed: Kev + claude-fable-5, 2026-08-16, Confidence 0.9 (red-first against
//  a counting fake driven through a real multi-call ReAct turn). Prior: Unknown.
//

import M1K3Agent
import M1K3Inference
import Testing

/// Counts generate calls and prepareForNextTurn calls. `@unchecked Sendable`:
/// mutation is confined to the agent's sequential awaits within one test.
private final class CountingWarmableProvider: InferenceProvider, TurnWarmable, @unchecked Sendable {
    let name = "counting-warmable"
    let isAvailable = true
    private(set) var generateCalls = 0
    private(set) var warmCalls = 0
    /// Markerless replies force the ReAct floor to re-prompt (extra calls)
    /// before the final CONCLUSION.
    var replies: [String]

    init(replies: [String]) {
        self.replies = replies
    }

    func generate(prompt _: String) async throws -> String {
        generateCalls += 1
        return replies.isEmpty ? "CONCLUSION: done" : replies.removeFirst()
    }

    func generateStreaming(prompt _: String) -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }

    func prepareForNextTurn() {
        warmCalls += 1
    }
}

struct TurnWarmingTests {
    @Test("a multi-call ReAct turn warms exactly once, at the end")
    func oncePerTurn() async throws {
        let provider = CountingWarmableProvider(replies: [
            "let me think about that", // markerless → re-prompt
            "still thinking", // markerless → re-prompt
            "CONCLUSION: the answer",
        ])
        let agent = LocalAgent(inferenceProvider: provider, tools: [], maxIterations: 5)
        _ = try await agent.run(goal: "hard question", context: nil)
        #expect(provider.generateCalls >= 3, "the fixture must actually exercise multiple calls")
        #expect(provider.warmCalls == 1)
    }

    @Test("a single-call turn also warms exactly once")
    func singleCallTurn() async throws {
        let provider = CountingWarmableProvider(replies: [])
        let agent = LocalAgent(inferenceProvider: provider, tools: [], maxIterations: 3)
        _ = try await agent.run(goal: "easy one", context: nil)
        #expect(provider.warmCalls == 1)
    }

    @Test("a cancelled turn does not warm — the successor turn owns the daemon")
    func cancelledTurnSkipsWarm() async throws {
        // Deliberate behavior, not an accident of defer placement: a cancelled
        // turn means the user is mid-send, and a prewarm now would compete
        // with the successor turn's own generation.
        final class HangingWarmableProvider: InferenceProvider, TurnWarmable, @unchecked Sendable {
            let name = "hanging"
            let isAvailable = true
            private(set) var warmCalls = 0
            func generate(prompt _: String) async throws -> String {
                try await Task.sleep(for: .seconds(10))
                return "CONCLUSION: never"
            }

            func generateStreaming(prompt _: String) -> AsyncStream<String> {
                AsyncStream { $0.finish() }
            }

            func prepareForNextTurn() {
                warmCalls += 1
            }
        }
        let provider = HangingWarmableProvider()
        let agent = LocalAgent(inferenceProvider: provider, tools: [], maxIterations: 1)
        let turn = Task { try await agent.run(goal: "q", context: nil) }
        try await Task.sleep(for: .milliseconds(50))
        turn.cancel()
        _ = try? await turn.value
        #expect(provider.warmCalls == 0)
    }

    @Test("a non-conforming provider is untouched — the seam is opt-in")
    func nonConformingIsFine() async throws {
        struct Plain: InferenceProvider {
            let name = "plain"
            let isAvailable = true
            func generate(prompt _: String) async throws -> String {
                "CONCLUSION: ok"
            }

            func generateStreaming(prompt _: String) -> AsyncStream<String> {
                AsyncStream { $0.finish() }
            }
        }
        let agent = LocalAgent(inferenceProvider: Plain(), tools: [], maxIterations: 1)
        _ = try await agent.run(goal: "q", context: nil)
        // Reaching here without a crash IS the assertion: the cast is optional.
    }
}
