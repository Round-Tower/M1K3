//
//  PlainTurnRouteTests.swift
//  M1K3ChatTests
//
//  The plain-chat route (Kev, 2026-09-26): a turn the tool router reads as chat
//  is answered by ONE streamed generation with no tool palette and no tool
//  talk in the prompt, instead of the agent loop. A live A/B measured the same
//  Mini chat turn at 51.5 s with the palette and 13.4 s without; an empty
//  palette through the AGENT prompt produced junk, hence a route of its own.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-26, Confidence 0.8. Prior: Unknown.
//

import Foundation
import M1K3Agent
@testable import M1K3Chat
import M1K3Inference
import M1K3Knowledge
import Synchronization
import Testing

// MARK: - Fakes

/// Streams scripted responses word by word (cumulative, like AFM), records each
/// prompt, the instructions override in force for it, and every turn re-arm.
private final class RouteProvider: InferenceProvider, TurnWarmable, @unchecked Sendable {
    let name = "route-scripted"
    let isAvailable = true
    private let state = Mutex<(responses: [String], prompts: [String], instructions: [String?], warms: [String?])>(
        ([], [], [], [])
    )

    /// `deltas`: the responses are the PIECES of one answer, streamed as deltas
    /// (the MLX shape), rather than one scripted answer per call.
    private let deltaPieces: [String]?

    init(_ responses: [String], deltas: Bool = false) {
        deltaPieces = deltas ? responses : nil
        state.withLock { $0.responses = deltas ? [responses.joined()] : responses }
    }

    private func next(_ prompt: String) -> String {
        state.withLock {
            $0.prompts.append(prompt)
            $0.instructions.append(InferenceIntent.instructions)
            return $0.responses.isEmpty ? "" : $0.responses.removeFirst()
        }
    }

    func generate(prompt: String) async throws -> String {
        next(prompt)
    }

    func generateStreaming(prompt: String) -> AsyncStream<String> {
        let response = next(prompt)
        if let deltaPieces {
            return AsyncStream { continuation in
                deltaPieces.forEach { continuation.yield($0) }
                continuation.finish()
            }
        }
        return AsyncStream { continuation in
            var emitted = ""
            for word in response.split(separator: " ", omittingEmptySubsequences: false) where !response.isEmpty {
                emitted += (emitted.isEmpty ? "" : " ") + word
                continuation.yield(emitted)
            }
            continuation.finish()
        }
    }

    func prepareForNextTurn(promptPrefix: String?) {
        state.withLock { $0.warms.append(promptPrefix) }
    }

    var prompts: [String] {
        state.withLock { $0.prompts }
    }

    var instructions: [String?] {
        state.withLock { $0.instructions }
    }

    var warms: [String?] {
        state.withLock { $0.warms }
    }
}

private struct NoteTool: AgentTool {
    let name = "search_knowledge"
    let description = "Search the user's stored documents."
    let parameters = [ToolParameter(name: "query", description: "what to find")]
    func execute(input _: [String: String]) async throws -> ToolResult {
        ToolResult(output: "nothing")
    }
}

private final class Consulted: Sendable {
    let count = Mutex(0)
}

private final class ActivityLog: Sendable {
    let items = Mutex<[ResponderActivity]>([])
}

private func responder(
    _ provider: RouteProvider,
    route: PlainTurnRoute?,
    consulted: Consulted = Consulted()
) throws -> AgentRAGResponder {
    try AgentRAGResponder(
        store: KnowledgeStore(), embedder: HashingEmbeddingService(), provider: provider,
        toolsProvider: { [NoteTool()] },
        plainRouteProvider: route.map { route in
            { @Sendable in
                PlainTurnRoute(
                    decide: { question in
                        consulted.count.withLock { $0 += 1 }
                        return route.decide(question)
                    },
                    instructions: route.instructions
                )
            }
        }
    )
}

private func chat(_ verdict: ToolNeedRouter.Verdict, instructions: String? = nil) -> PlainTurnRoute {
    PlainTurnRoute(decide: { _ in .init(verdict: verdict, probability: 0.1) }, instructions: instructions)
}

private func answer(
    _ responder: AgentRAGResponder, _ question: String,
    images: [ImageAttachment] = [], history: [ChatTurn] = [],
    activities: ActivityLog? = nil
) async throws -> String {
    var text = ""
    let stream = try await responder.answerStreaming(
        question, images: images, history: history,
        onActivity: { activity in activities?.items.withLock { $0.append(activity) } }
    ).stream
    for await piece in stream {
        text = StreamFold.fold(current: text, chunk: piece)
    }
    return text
}

// MARK: - The route

struct PlainTurnRouteTests {
    @Test("chat verdict: one streamed generation, a tool-free prompt ending in the question")
    func chatVerdictRunsPlainTurn() async throws {
        let provider = RouteProvider(["Hello there, lovely to hear from you."])
        let activities = ActivityLog()
        let text = try await answer(
            responder(provider, route: chat(.chat)), "hi, how are you?", activities: activities
        )
        #expect(text == "Hello there, lovely to hear from you.")
        #expect(provider.prompts.count == 1)
        let prompt = try #require(provider.prompts.first)
        #expect(prompt.hasSuffix("USER: hi, how are you?"))
        #expect(!prompt.localizedCaseInsensitiveContains("tool"), "the plain prompt talks about tools")
        #expect(activities.items.withLock { $0 }.contains(.thinking(iteration: 0)))
        #expect(provider.warms == [nil], "the plain turn re-arms the next turn itself")
    }

    @Test("tools verdict: the agent loop runs exactly as without a router")
    func toolsVerdictRunsAgent() async throws {
        let routed = RouteProvider(["CONCLUSION: done"])
        _ = try await answer(responder(routed, route: chat(.tools)), "search my notes for the seal spec")
        let plain = RouteProvider(["CONCLUSION: done"])
        _ = try await answer(responder(plain, route: nil), "search my notes for the seal spec")
        #expect(routed.prompts.count == plain.prompts.count)
        #expect(routed.prompts.first?.localizedCaseInsensitiveContains("tool") == true)
    }

    @Test("an empty plain stream falls back to the agent loop, never a blank bubble")
    func emptyPlainFallsBack() async throws {
        let provider = RouteProvider(["", "CONCLUSION: Canberra."])
        let text = try await answer(responder(provider, route: chat(.chat)), "capital of Australia?")
        #expect(text.contains("Canberra"))
        #expect(provider.prompts.count == 2)
        // PR #414 review: the plain turn doesn't re-arm when the agent turn takes over
        // (it re-arms itself); two back-to-back prewarms strain the AFM daemon.
        #expect(provider.warms.count == 1, "one re-arm, the agent turn's: \(provider.warms)")
    }

    @Test("a turn with images never consults the router")
    func imagesSkipRouter() async throws {
        let consulted = Consulted()
        let provider = RouteProvider(["CONCLUSION: a fox"])
        let image = ImageAttachment(url: URL(fileURLWithPath: "/tmp/fox.png"))
        _ = try await answer(
            responder(provider, route: chat(.chat), consulted: consulted), "what's this?", images: [image]
        )
        #expect(consulted.count.withLock { $0 } == 0)
    }

    @Test("the route's instructions ride the plain generation; nil keeps the provider's own")
    func instructionsOverride() async throws {
        let withPersona = RouteProvider(["Grand."])
        _ = try await answer(responder(withPersona, route: chat(.chat, instructions: "PERSONA")), "hello")
        #expect(withPersona.instructions == ["PERSONA"])
        let providerOwn = RouteProvider(["Grand."])
        _ = try await answer(responder(providerOwn, route: chat(.chat)), "hello")
        #expect(providerOwn.instructions == [nil])
    }

    @Test("the history replay reaches the plain prompt")
    func historyReplay() async throws {
        let provider = RouteProvider(["It was the boiler."])
        let history = [
            ChatTurn(role: .user, text: "The landlord is sending someone about the boiler."),
            ChatTurn(role: .assistant, text: "Good, that's been a while coming."),
        ]
        _ = try await answer(responder(provider, route: chat(.chat)), "what was I on about?", history: history)
        #expect(provider.prompts.first?.contains("boiler") == true)
    }

    @Test("a delta-streaming brain (MLX-shaped) loses nothing on the plain route")
    func deltaProvider() async throws {
        let provider = RouteProvider(["M", "ostly sunny, I'd say."], deltas: true)
        let text = try await answer(responder(provider, route: chat(.chat)), "nice day?")
        #expect(text == "Mostly sunny, I'd say.")
    }

    @Test("a leading speaker label is stripped from the plain stream")
    func speakerLabelStripped() async throws {
        let provider = RouteProvider(["M1K3: Grand, thanks for asking."])
        let text = try await answer(responder(provider, route: chat(.chat)), "how are you?")
        #expect(text == "Grand, thanks for asking.")
    }
}

/// MLX brains (Lil/Big) stream DELTAS, not AFM's cumulative snapshots (code
/// review, 2026-09-26): a first delta "M" held as a possible label must not be
/// lost when the next one shows it was the start of "Mostly".
struct PlainTurnStreamDeltaTests {
    private func run(_ chunks: [String]) -> [String] {
        var stream = PlainTurnStream()
        return chunks.compactMap { stream.ingest($0) }
    }

    @Test("deltas: a held first piece is replayed once the label is ruled out")
    func heldDeltaReplayed() {
        let out = run(["M", "ostly", " sunny"])
        #expect(out.last == "Mostly sunny")
        #expect(out.first == "Mostly")
    }

    @Test("deltas: a label split across pieces is cut")
    func splitLabelCut() {
        #expect(run(["M", "1K", "3:", " Grand", ", thanks"]).last == "Grand, thanks")
    }

    @Test("snapshots still work, and every yield extends the last (the consumer folds snapshots)")
    func snapshotsMonotonic() {
        let out = run(["M1", "M1K3:", "M1K3: Hi", "M1K3: Hi there"])
        #expect(out == ["Hi", "Hi there"])
        for (earlier, later) in zip(out, out.dropFirst()) {
            #expect(later.hasPrefix(earlier))
        }
    }
}

struct PlainTurnStreamTests {
    @Test("snapshots that could still become the label are held; the label is cut")
    func labelHandling() {
        #expect(PlainTurnStream.clean("M") == nil)
        #expect(PlainTurnStream.clean("M1K3") == nil)
        #expect(PlainTurnStream.clean("M1K3:") == nil)
        #expect(PlainTurnStream.clean("M1K3: Hi") == "Hi")
        #expect(PlainTurnStream.clean("  M1K3:  Hi there") == "Hi there")
        #expect(PlainTurnStream.clean("Mostly sunny") == "Mostly sunny")
        #expect(PlainTurnStream.clean("Hello") == "Hello")
        // PR #414 review: leading whitespace (a tokenizer artifact) must not ride into the bubble.
        #expect(PlainTurnStream.clean("  Well, hi") == "Well, hi")
    }
}
