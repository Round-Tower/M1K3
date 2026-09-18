//
//  ConclusionStreamSplitterTests.swift
//  M1K3AgentTests
//
//  The splitter is why the agent's final answer streams token-by-token
//  instead of arriving as one dump: it buffers a thought until the
//  CONCLUSION: marker appears, then passes everything after it through
//  live. Must handle BOTH provider stream contracts (cumulative snapshots
//  and deltas) and a marker split across token boundaries.
//
//  Signed: Kev + claude-fable-5, 2026-06-09, Confidence 0.9, Prior: Unknown

import Foundation
@testable import M1K3Agent
import M1K3Inference
import Testing

struct ConclusionStreamSplitterTests {
    /// Run a chunk sequence through a splitter and collect everything it
    /// emits, including the flush (the held-back guard window).
    private func collect(_ chunks: [String], into splitter: inout ConclusionStreamSplitter) -> String {
        var out = ""
        for chunk in chunks {
            out += splitter.feed(chunk)
        }
        out += splitter.flush()
        return out
    }

    @Test("delta tokens: buffers until the marker, then passes the tail live")
    func deltaTokens() {
        var splitter = ConclusionStreamSplitter()
        let emitted = collect(
            ["I think ", "CONCLU", "SION: The answer", " is 42."],
            into: &splitter
        )
        #expect(emitted == "The answer is 42.")
        #expect(splitter.isConclusion)
        #expect(splitter.thought == "I think CONCLUSION: The answer is 42.")
    }

    @Test("cumulative snapshots (AFM contract) are normalised to deltas")
    func cumulativeSnapshots() {
        var splitter = ConclusionStreamSplitter()
        let emitted = collect(
            ["CONCLUSION: The", "CONCLUSION: The answer"],
            into: &splitter
        )
        #expect(emitted == "The answer")
        #expect(splitter.thought == "CONCLUSION: The answer")
    }

    @Test("a thought with no marker emits nothing, even flushed")
    func noMarker() {
        var splitter = ConclusionStreamSplitter()
        let emitted = collect(["ACTION: search(x)", " more reasoning"], into: &splitter)
        #expect(emitted.isEmpty)
        #expect(!splitter.isConclusion)
        #expect(splitter.thought == "ACTION: search(x) more reasoning")
    }

    @Test("leading whitespace after the marker is not emitted as a stray first token")
    func trimsAfterMarker() {
        var splitter = ConclusionStreamSplitter()
        let emitted = collect(["CONCLUSION:   ", "Clean answer."], into: &splitter)
        #expect(emitted == "Clean answer.")
    }

    @Test("an ACTION after the conclusion is cut — scaffolding never streams to the user")
    func truncatesAtAction() {
        var splitter = ConclusionStreamSplitter()
        let emitted = collect(
            ["CONCLUSION: Done.", "\nACTION: search(more)", " trailing"],
            into: &splitter
        )
        #expect(emitted == "Done.")
    }

    @Test("an ACTION marker split across chunks is still caught")
    func truncatesSplitActionMarker() {
        var splitter = ConclusionStreamSplitter()
        let emitted = collect(
            ["CONCLUSION: Fine so far. ", "ACT", "ION: go(x)"],
            into: &splitter
        )
        #expect(emitted == "Fine so far.")
    }

    @Test("post-ACTION prose resumes with a separator, not glued to the prior sentence")
    func resumesWithSeparator() {
        var splitter = ConclusionStreamSplitter()
        let emitted = collect(
            ["CONCLUSION: I'll check.\nACTION: lookup(Paris)\nHere's what I know."],
            into: &splitter
        )
        #expect(emitted.contains("I'll check."))
        #expect(emitted.contains("Here's what I know."))
        #expect(!emitted.contains("I'll check.Here"))
    }

    @Test("a second ACTION after resumed prose does not leak through flush")
    func secondActionDoesNotLeak() {
        var splitter = ConclusionStreamSplitter()
        let emitted = collect(
            ["CONCLUSION: I'll check.\nACTION: lookup(Paris)\nHere's what I know.\nACTION: lookup(Rome)\nMore prose."],
            into: &splitter
        )
        #expect(emitted.contains("I'll check."))
        #expect(emitted.contains("Here's what I know."))
        #expect(!emitted.contains("lookup(Rome)"))
        #expect(emitted.contains("More prose."))
    }

    @Test("emission is incremental — most of the conclusion arrives before the flush")
    func emitsIncrementally() {
        var splitter = ConclusionStreamSplitter()
        let first = splitter.feed("CONCLUSION: A reasonably long streamed answer")
        #expect(first.hasPrefix("A reasonably long streamed"))
        let rest = splitter.flush()
        #expect(first + rest == "A reasonably long streamed answer")
    }
}

struct LocalAgentConclusionStreamingTests {
    /// Streams scripted thoughts word-by-word via generateStreaming; generate()
    /// only serves the synthesis path.
    private final class StreamingScriptedProvider: InferenceProvider, @unchecked Sendable {
        let name = "streaming-scripted"
        let isAvailable = true

        private let lock = NSLock()
        private var responses: [String]
        private(set) var prompts: [String] = []

        init(_ responses: [String]) {
            self.responses = responses
        }

        func generate(prompt: String) async throws -> String {
            lock.withLock {
                prompts.append(prompt)
                return responses.isEmpty ? "synthesised" : responses.removeFirst()
            }
        }

        func generateStreaming(prompt: String) -> AsyncStream<String> {
            let response: String = lock.withLock {
                prompts.append(prompt)
                return responses.isEmpty ? "CONCLUSION: (fallback)" : responses.removeFirst()
            }
            return AsyncStream { continuation in
                var emitted = ""
                for word in response.split(separator: " ", omittingEmptySubsequences: false) {
                    emitted += (emitted.isEmpty ? "" : " ") + word
                    continuation.yield(emitted) // cumulative, like AFM
                }
                continuation.finish()
            }
        }
    }

    @Test("the conclusion's tail streams live through onConclusionToken")
    func conclusionStreamsLive() async throws {
        let provider = StreamingScriptedProvider([
            "ACTION: lookup(x)",
            "CONCLUSION: The seal failed under load.",
        ])
        let tool = EchoTool(name: "lookup", description: "looks up", response: "found")
        let agent = LocalAgent(inferenceProvider: provider, tools: [tool])

        let collector = TokenCollector()
        let result = try await agent.run(goal: "what failed?", onConclusionToken: { token in
            collector.append(token)
        })

        #expect(result.conclusion == "The seal failed under load.")
        // The action thought never leaked; the conclusion tail did, in pieces.
        let streamed = collector.joined
        #expect(streamed == "The seal failed under load.")
        #expect(collector.count > 1)
    }

    @Test("prose after a mid-conclusion ACTION line is not lost (#329)")
    func midConclusionActionProseCarried() async throws {
        let provider = StreamingScriptedProvider([
            "CONCLUSION: I'll check.\nACTION: lookup(Paris)\nHere's what I know: the city is on the Seine.",
        ])
        let tool = EchoTool(name: "lookup", description: "looks up", response: "found")
        let agent = LocalAgent(inferenceProvider: provider, tools: [tool])

        let collector = TokenCollector()
        let result = try await agent.run(goal: "tell me about Paris", onConclusionToken: { token in
            collector.append(token)
        })

        #expect(result.conclusion.contains("Here's what I know"))
        let streamed = collector.joined
        #expect(streamed.contains("Here's what I know"))
    }

    @Test("without the callback the loop still uses blocking generation")
    func blockingPathUnchanged() async throws {
        let provider = StreamingScriptedProvider(["CONCLUSION: fine"])
        let agent = LocalAgent(inferenceProvider: provider, tools: [])
        let result = try await agent.run(goal: "x")
        #expect(result.conclusion == "fine")
    }
}

private final class TokenCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String] = []

    func append(_ token: String) {
        lock.withLock { tokens.append(token) }
    }

    var joined: String {
        lock.withLock { tokens.joined() }
    }

    var count: Int {
        lock.withLock { tokens.count }
    }
}
