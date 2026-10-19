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
//  Review: Kev + claude-opus-5-5, 2026-09-27 — the plain prompt carries no date line and no
//  remembered-thread cue (#428/#349). Confidence 0.8.
//  Review: Kev + claude-opus-5-5, 2026-10-16 — pins `promptAnatomy` (history vs rest, in characters).
//  Review: Kev + claude-opus-5-5, 2026-10-17 — and its ` · earlier N` count of the trace (#626).
//  Review: Kev + claude-opus-5-5, 2026-10-17 — #622: pointing back at this chat skips the picker, with history only.
//  Review: Kev + claude-opus-5.5, 2026-10-17 — a plain turn that thinks to the cap without answering
//  answers straight after it (the live Always-think dead bubble); the fake records the turn's thinking.
//  Review: Kev + claude-opus-5-5, 2026-10-18 — the thinking cap: reasoning past the budget is cut and answered
//  straight; closed reasoning is never cut.
//  Review: Kev + claude-opus-5-5, 2026-10-19 — a brain that forces its own close (the fake conforms to
//  `ThinkBudgetForcing`) moves the cut to a net at 8 characters a token; both bounds of the net are pinned.
//  Review: Kev + claude-opus-5-5, 2026-10-19 — `imagesSkipRouter` runs on a tool-calling double: an image on a brain
//  that can't carry it is now declined before the router, so the plain double would pass for the wrong reason.
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
/// prompt, the instructions and thinking decision in force for it, and every turn re-arm.
private final class RouteProvider: ThinkBudgetForcing, TurnWarmable, @unchecked Sendable {
    let name = "route-scripted"
    let isAvailable = true
    /// A brain that closes its own thought at this many tokens (Lil's forcing); nil, as most scripts, doesn't.
    let forcedThinkingTokens: Int?
    private let state = Mutex<(
        responses: [String], prompts: [String], instructions: [String?], thinking: [Bool?], warms: [String?]
    )>(([], [], [], [], []))

    /// `deltas`: the responses are the PIECES of one answer, streamed as deltas
    /// (the MLX shape), rather than one scripted answer per call.
    private let deltaPieces: [String]?

    init(_ responses: [String], deltas: Bool = false, forcedThinkingTokens: Int? = nil) {
        self.forcedThinkingTokens = forcedThinkingTokens
        deltaPieces = deltas ? responses : nil
        state.withLock { $0.responses = deltas ? [responses.joined()] : responses }
    }

    private func next(_ prompt: String) -> String {
        state.withLock {
            $0.prompts.append(prompt)
            $0.instructions.append(InferenceIntent.instructions)
            $0.thinking.append(InferenceIntent.thinking)
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

    var thinking: [Bool?] {
        state.withLock { $0.thinking }
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

/// A tool-calling brain that answers in one turn: an image turn reaches the agent route with it.
private final class SeeingToolProvider: ToolCallingProvider, @unchecked Sendable {
    let name = "seeing-tool"
    let isAvailable = true
    let supportsToolCalls = true

    private final class Session: ToolTurnSession, @unchecked Sendable {
        func send(_: [ToolMessage], onToken: @escaping @Sendable (String) -> Void) async throws -> ToolTurn {
            onToken("A fox.")
            return .text("A fox.")
        }
    }

    func makeToolTurnSession(
        tools _: [ToolDefinition], options _: ToolTurnOptions
    ) async throws -> any ToolTurnSession {
        Session()
    }

    func continueToolTurn(messages _: [ToolMessage], tools _: [ToolDefinition]) async throws -> ToolTurn {
        .text("A fox.")
    }

    func generate(prompt _: String) async throws -> String {
        "A fox."
    }

    func generateStreaming(prompt _: String) -> AsyncStream<String> {
        AsyncStream { continuation in
            continuation.yield("A fox.")
            continuation.finish()
        }
    }
}

private func responder(
    _ provider: any InferenceProvider,
    route: PlainTurnRoute?,
    consulted: Consulted = Consulted(),
    egress: String? = nil,
    mode: ThinkingMode = .auto,
    thinkingBudget: Int = ThinkingPolicy.thinkingBudgetCharacters
) throws -> AgentRAGResponder {
    try AgentRAGResponder(
        store: KnowledgeStore(), embedder: HashingEmbeddingService(), provider: provider,
        toolsProvider: { [NoteTool()] },
        thinkingModeProvider: { mode },
        thinkingBudget: thinkingBudget,
        egressClauseProvider: { egress },
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

    /// #428/#349 (2026-09-27, MiniInventedMemoryEvalTests): Mini opened small talk on the
    /// turn's date 11/16 and invented a shared past ("you once asked about pairing spices")
    /// 6/14. Without the date line and the "a memory of them, the hour" thread: 1/16 and 2–3/14.
    @Test("the plain prompt carries no date line and no remembered-thread cue")
    func plainPromptHasNoDateOrThreadCue() async throws {
        let provider = RouteProvider(["Not much, you?"])
        _ = try await answer(responder(provider, route: chat(.chat)), "what's up?")
        let prompt = try #require(provider.prompts.first)
        #expect(!prompt.contains("Right now (true for this turn)"))
        #expect(!prompt.contains("a memory of them"))
        #expect(!prompt.contains("the hour"))
    }

    /// #482: Mini's plain turn is where "does anything leave this device?" lands.
    @Test("the plain prompt carries the egress clause")
    func plainPromptCarriesEgress() async throws {
        let provider = RouteProvider(["Web searches can."])
        _ = try await answer(responder(provider, route: chat(.chat), egress: "EGRESS-FACTS"), "does anything leave?")
        #expect(try #require(provider.prompts.first).contains("EGRESS-FACTS"))
    }

    /// #430 (375 over MCP): "How's my battery doing?" answered as a plain turn and worked in a
    /// stored call note, a decode benchmark and a script. MiniRetrievalNoiseEvalTests: excerpts
    /// leaked into 3/10 noise probes, 0/10 without them; and the router sends every document
    /// question it was probed with to the tools (15/15, p 0.74–0.98), where search_knowledge
    /// and the agent keep their excerpts. So a plain turn carries none.
    @Test("a plain turn carries no knowledge excerpts, no 'found nothing' head, and lists none as sources")
    func plainTurnDropsExcerpts() async throws {
        let (store, embedder) = try await plantNotes()
        let question = Self.sealQuestion
        // Control: the agent turn (no router) does retrieve and carry the excerpt.
        let agent = RouteProvider(["CONCLUSION: it failed."])
        let unrouted = AgentRAGResponder(
            store: store, embedder: embedder, provider: agent, toolsProvider: { [NoteTool()] }
        )
        let (agentSources, agentStream) = try await unrouted.answerStreaming(
            question, images: [], history: [], onActivity: { _ in }
        )
        for await _ in agentStream {}
        // "failed under load" is the excerpt's alone (the question names the seal itself).
        try #require(agent.prompts.first?.contains("failed under load") == true, "the excerpt isn't retrieved at all")
        #expect(agentSources.contains { $0.itemTitle == "Plant Notes" })

        let provider = RouteProvider(["All quiet on the conveyor front."])
        let responder = AgentRAGResponder(
            store: store, embedder: embedder, provider: provider,
            toolsProvider: { [NoteTool()] },
            plainRouteProvider: { chat(.chat) }
        )
        let (sources, stream) = try await responder.answerStreaming(
            question, images: [], history: [], onActivity: { _ in }
        )
        for await _ in stream {}
        let prompt = try #require(provider.prompts.first)
        #expect(!prompt.contains("failed under load"))
        #expect(!prompt.contains("No stored knowledge"))
        #expect(!sources.contains { $0.itemTitle == "Plant Notes" })
    }

    static let sealQuestion = "what happened with the hydraulic seal on the conveyor?"

    /// A store whose one document answers `sealQuestion`; "failed under load" is the excerpt's
    /// alone (the question names the seal itself).
    private func plantNotes() async throws -> (KnowledgeStore, HashingEmbeddingService) {
        let store = try KnowledgeStore()
        let embedder = HashingEmbeddingService()
        try await DocumentIngester(store: store, embedder: embedder).ingest(
            title: "Plant Notes",
            pages: [DocumentPage(pageNumber: 1, text: "3.2 Seals\nThe hydraulic seal on the conveyor failed under load.")]
        )
        return (store, embedder)
    }

    @Test("#438 review: a chat verdict's excerpts stay out of the agent turn a blank plain turn hands to")
    func chatVerdictFallbackCarriesNoExcerpts() async throws {
        let (store, embedder) = try await plantNotes()
        let provider = RouteProvider(["", "CONCLUSION: it failed."])
        let responder = AgentRAGResponder(
            store: store, embedder: embedder, provider: provider,
            toolsProvider: { [NoteTool()] }, plainRouteProvider: { chat(.chat) }
        )
        let (sources, stream) = try await responder.answerStreaming(
            Self.sealQuestion, images: [], history: [], onActivity: { _ in }
        )
        for await _ in stream {}
        try #require(provider.prompts.count == 2, "the agent turn never took over")
        #expect(!provider.prompts.contains { $0.contains("failed under load") })
        // The sources name only what could reach a prompt.
        #expect(!sources.contains { $0.itemTitle == "Plant Notes" })
    }

    /// #622: "What did you say about names earlier?" scored tools (0.66), Apple's picker ran
    /// recent_activity, and another chat's facts reached the answer. With history, a question that
    /// points back at this chat is the replay's: one plain generation, no picker.
    @Test("a question pointing back at this chat answers from it, with history; without, the picker runs")
    func pointingBackSkipsThePicker() async throws {
        let picks = Mutex(0)
        let route = PlainTurnRoute(
            decide: { _ in .init(verdict: .tools, probability: 0.66) }, instructions: nil,
            pick: { @Sendable _, _ in
                picks.withLock { $0 += 1 }
                return ToolPick(tool: ToolPick.noTool, query: "")
            }
        )
        let history = [
            ChatTurn(role: .user, text: "Any good names for a black cat?"),
            ChatTurn(role: .assistant, text: "Nyx, Onyx or Vesper."),
        ]
        let provider = RouteProvider(["I suggested Nyx, Onyx and Vesper."])
        let responder = try AgentRAGResponder(
            store: KnowledgeStore(), embedder: HashingEmbeddingService(), provider: provider,
            toolsProvider: { [NoteTool()] }, plainRouteProvider: { route }
        )
        _ = try await answer(responder, "What did you say about names earlier?", history: history)
        #expect(picks.withLock { $0 } == 0)
        #expect(provider.prompts.count == 1)

        let fresh = RouteProvider(["Nothing yet."])
        let freshResponder = try AgentRAGResponder(
            store: KnowledgeStore(), embedder: HashingEmbeddingService(), provider: fresh,
            toolsProvider: { [NoteTool()] }, plainRouteProvider: { route }
        )
        _ = try await answer(freshResponder, "What did you say about names earlier?")
        #expect(picks.withLock { $0 } == 1)
    }

    /// Code review, 2026-10-17: a confident tools verdict (a past-session look-back sits ~0.87)
    /// keeps the picker even when the words point back: the override is for the gate's grey zone.
    @Test("a confident tools verdict keeps the picker even when the words point back")
    func confidentToolsVerdictKeepsThePicker() async throws {
        let picks = Mutex(0)
        let route = PlainTurnRoute(
            decide: { _ in .init(verdict: .tools, probability: 0.9) }, instructions: nil,
            pick: { @Sendable _, _ in
                picks.withLock { $0 += 1 }
                return ToolPick(tool: ToolPick.noTool, query: "")
            }
        )
        let provider = RouteProvider(["Here it is."])
        let responder = try AgentRAGResponder(
            store: KnowledgeStore(), embedder: HashingEmbeddingService(), provider: provider,
            toolsProvider: { [NoteTool()] }, plainRouteProvider: { route }
        )
        let history = [ChatTurn(role: .user, text: "hi"), ChatTurn(role: .assistant, text: "hello")]
        _ = try await answer(responder, "What did you say about names earlier?", history: history)
        #expect(picks.withLock { $0 } == 1)
    }

    @Test("#438 review: a tools verdict's plain fallback keeps its excerpts, and lists them")
    func toolsVerdictPlainFallbackKeepsExcerpts() async throws {
        let (store, embedder) = try await plantNotes()
        let provider = RouteProvider(["It failed under load."])
        let route = PlainTurnRoute(
            decide: { _ in .init(verdict: .tools, probability: 0.9) }, instructions: nil,
            pick: { @Sendable _, _ in ToolPick(tool: ToolPick.noTool, query: "") }
        )
        let responder = AgentRAGResponder(
            store: store, embedder: embedder, provider: provider,
            toolsProvider: { [NoteTool()] }, plainRouteProvider: { route }
        )
        let (sources, stream) = try await responder.answerStreaming(
            Self.sealQuestion, images: [], history: [], onActivity: { _ in }
        )
        for await _ in stream {}
        #expect(provider.prompts.count == 1)
        #expect(provider.prompts.first?.contains("failed under load") == true)
        #expect(sources.contains { $0.itemTitle == "Plant Notes" })
    }

    @Test("#438 review: with no excerpts, the plain prompt drops the empty head and keeps the memories")
    func plainPromptKeepsMemoriesWithoutExcerpts() {
        let memory = ChunkHit(
            chunkID: UUID(), itemID: UUID(), itemTitle: "About the user", kind: .memory, heading: nil,
            content: "The user keeps a sourdough starter called Dough Nut."
        )
        let prompt = AgentRAGResponder.plainTurnPrompt(
            question: "any plans for the weekend?", contextPreamble: "",
            chunks: [], memories: [memory], history: [],
            historyBudget: HistoryBudgetPolicy.budget(
                for: .mini, reservedTokens: HistoryBudgetPolicy.liveReserveTokens,
                generationTokens: HistoryBudgetPolicy.liveGenerationReserveTokens
            ),
            ambient: nil, todos: nil
        )
        #expect(prompt.contains("Dough Nut"))
        #expect(!prompt.contains("No stored knowledge"))
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

    /// 2026-10-17, live on Always-think: Lil argued with the FOLLOWUPS rule until the cap, never
    /// closed </think>, and the bubble came up empty. The reasoning counted as "answered", so no
    /// fallback ran. Now the turn closes the reasoning and answers once more, thinking off.
    @Test("a plain turn that thinks to the cap without answering answers straight after it")
    func thoughtToCapAnswersStraight() async throws {
        let provider = RouteProvider(["<think>Wait, re-reading the FOLLOWUPS rule again", "Ray's grand, by the sound of it."])
        let text = try await answer(responder(provider, route: chat(.chat), mode: .always), "how's Ray?")
        let split = ReasoningSplit.split(text)
        #expect(split.answer == "Ray's grand, by the sound of it.")
        #expect(split.reasoning?.contains("FOLLOWUPS rule") == true, "the reasoning stays on show")
        #expect(provider.prompts.count == 2)
        #expect(provider.prompts.first == provider.prompts.last, "the same prompt, answered straight")
        #expect(provider.thinking == [true, false])
        #expect(provider.warms.count == 1, "answered: one re-arm")
    }

    /// The thinking cap (2026-10-18): on chat and reasoning alike Lil's Always-think scored what Auto did
    /// at ten times the time, thinking 2,500–4,500 tokens before a sum. Past the budget the think phase
    /// stops where it is and the turn answers straight, as a turn that thought to the token cap does.
    @Test("reasoning past the thinking budget is cut and answered straight")
    func thinkingPastBudgetIsCut() async throws {
        let provider = RouteProvider([
            "<think>Let me see. Nine years, twice that, so eighteen. But wait, maybe the TAIL-OF-THE-THOUGHT",
            "Mary is 18.",
        ])
        let text = try await answer(
            responder(provider, route: chat(.chat), mode: .always, thinkingBudget: 40), "how old is Mary?"
        )
        let split = ReasoningSplit.split(text)
        #expect(split.answer == "Mary is 18.")
        #expect(split.reasoning?.contains("Nine years") == true, "the thought so far stays on show")
        #expect(split.reasoning?.contains("TAIL-OF-THE-THOUGHT") == false, "the think phase stopped at the budget")
        #expect(provider.thinking == [true, false])
        #expect(text.components(separatedBy: "</think>").count == 2, "one close: \(text)")
    }

    /// Forcing ships for Lil (2026-10-19): the brain closes its own thought at 1,024 tokens, so the cut stands
    /// back to a net at 8 characters a token. A 4,000-character cut would race the close: 10 of 38 forced
    /// thoughts on the hard traps ran past 4,000 characters, and a cut thought is thrown away.
    @Test("a brain that closes its own thought moves the cut to a net above its budget")
    func forcingBrainMovesTheCut() async throws {
        let script = ["<think>Let me see. Nine years, twice that, so eighteen. Checked once.</think> Mary is 18."]
        // 10 tokens: an 80-character net, so the 62-character thought outlives the responder's 40.
        let forcing = RouteProvider(script, forcedThinkingTokens: 10)
        let kept = try await answer(
            responder(forcing, route: chat(.chat), mode: .always, thinkingBudget: 40), "how old is Mary?"
        )
        #expect(ReasoningSplit.split(kept).answer == "Mary is 18.")
        #expect(forcing.prompts.count == 1, "no cut, no retry")
        // The same thought on a brain that doesn't force is cut at 40 and answered again.
        let plain = RouteProvider(script + ["Mary is 18."])
        _ = try await answer(
            responder(plain, route: chat(.chat), mode: .always, thinkingBudget: 40), "how old is Mary?"
        )
        #expect(plain.prompts.count == 2)
    }

    @Test("past the net, a forcing brain's thought is still cut and answered straight")
    func forcingBrainPastTheNetIsCut() async throws {
        let provider = RouteProvider([
            "<think>Nine years, twice that, so eighteen. Check it. Check it again. And again, once more. TAIL-OF-IT",
            "Mary is 18.",
        ], forcedThinkingTokens: 10)
        let text = try await answer(
            responder(provider, route: chat(.chat), mode: .always, thinkingBudget: 40), "how old is Mary?"
        )
        #expect(ReasoningSplit.split(text).answer == "Mary is 18.")
        #expect(ReasoningSplit.split(text).reasoning?.contains("TAIL-OF-IT") == false, "cut at the 80-character net")
        #expect(ReasoningSplit.split(text).reasoning?.contains("And again") == true, "not cut at the responder's 40")
        #expect(provider.thinking == [true, false])
    }

    @Test("an answer after closed reasoning is never cut, however long the answer")
    func closedReasoningIsNotCut() async throws {
        let long = "Mary is 18, twice her brother's 9, and she will stay nine years older than him for good."
        let provider = RouteProvider(["<think>Twice 9.</think> " + long])
        let text = try await answer(
            responder(provider, route: chat(.chat), mode: .always, thinkingBudget: 20), "how old is Mary?"
        )
        #expect(ReasoningSplit.split(text).answer == long)
        #expect(provider.prompts.count == 1)
    }

    /// PR review: reasoning that DID close, with nothing after it, is answered straight too, and
    /// the retry must not add a second close (a stray `</think>` would sit in the bubble).
    @Test("closed reasoning with an empty answer retries without a second close tag", arguments: [
        "<think>Round and round</think>", "Round and round</think>",
    ])
    func closedEmptyRetriesWithOneClose(first: String) async throws {
        let provider = RouteProvider([first, "Canberra."])
        let text = try await answer(responder(provider, route: chat(.chat), mode: .always), "capital of Australia?")
        #expect(ReasoningSplit.split(text).answer == "Canberra.")
        #expect(text.components(separatedBy: "</think>").count == 2, "exactly one close: \(text)")
        #expect(provider.thinking.last == false)
    }

    @Test("reasoning that closes into an answer is one generation")
    func closedReasoningIsOneGeneration() async throws {
        let provider = RouteProvider(["<think>Easy one.</think> Canberra."])
        let text = try await answer(responder(provider, route: chat(.chat), mode: .always), "capital of Australia?")
        #expect(ReasoningSplit.split(text).answer == "Canberra.")
        #expect(provider.prompts.count == 1)
    }

    @Test("thinking to the cap and then nothing hands the turn to the agent, never a blank bubble")
    func thoughtToCapThenEmptyFallsBack() async throws {
        let provider = RouteProvider(["<think>Round and round", "", "CONCLUSION: Canberra."])
        let text = try await answer(responder(provider, route: chat(.chat), mode: .always), "capital of Australia?")
        #expect(ReasoningSplit.split(text).answer.contains("Canberra"))
        #expect(provider.prompts.count == 3)
    }

    /// A brain that can carry the image (2026-10-19): one that can't is declined before the router is reached, so
    /// a plain double would pass this for the wrong reason.
    @Test("a turn with images never consults the router")
    func imagesSkipRouter() async throws {
        let consulted = Consulted()
        let provider = SeeingToolProvider()
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
    @Test("only reasoning still open counts against the thinking budget")
    func thinkingBudget() {
        var open = PlainTurnStream()
        _ = open.ingest("<think>one two three four")
        #expect(open.thinkingPastBudget(10))
        #expect(!open.thinkingPastBudget(100))
        var closed = PlainTurnStream()
        _ = closed.ingest("<think>one two three four</think>")
        #expect(!closed.thinkingPastBudget(10), "closed: the answer is on its way")
        var plain = PlainTurnStream()
        _ = plain.ingest("A plain answer that runs well past ten characters.")
        #expect(!plain.thinkingPastBudget(10))
    }

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

    @Test("an answer is text outside the reasoning; a stream cut mid-thought has none")
    func answerVersusReasoning() {
        func stream(_ chunks: String...) -> PlainTurnStream {
            var stream = PlainTurnStream()
            chunks.forEach { _ = stream.ingest($0) }
            return stream
        }
        #expect(!stream().hasAnswer)
        #expect(stream("Hi").hasAnswer)
        #expect(stream("<think>", "hmm, the rule says").hasAnswer == false)
        #expect(stream("<think>", "hmm, the rule says").thoughtWithoutAnswering)
        #expect(stream("<think>hmm</think>", " Hi").hasAnswer)
        #expect(!stream("<think>hmm</think>", " Hi").thoughtWithoutAnswering)
        // The template pre-opens the block, so a model may emit only the close.
        #expect(stream("hmm</think>").thoughtWithoutAnswering)
        #expect(!stream("Hi").thoughtWithoutAnswering)
    }
}

/// 2026-10-16: the voice rig read ~1,900 tokens past Big's persona seed on every plain turn,
/// and nothing said how much of it was the history replay. The challenger's step 0: measure
/// the split before building a history cache or capping the window.
struct PlainPromptAnatomyTests {
    @Test("the anatomy line splits the prompt into the history replay and everything else")
    func anatomySplitsHistory() {
        let history = [
            ChatTurn(role: .user, text: "The landlord is sending someone about the boiler."),
            ChatTurn(role: .assistant, text: "Good, that's been a while coming."),
        ]
        let budget = HistoryWindow.Budget.default
        let replay = HistoryWindow.render(history, budget: budget) ?? ""
        let prompt = "identity\n\n" + replay + "\n\nRULES\n\nUSER: hi"
        let line = AgentRAGResponder.promptAnatomy(prompt: prompt, history: history, budget: budget)
        #expect(line == "prompt anatomy: \(prompt.count)c · history \(replay.count)c in 2 turns · rest \(prompt.count - replay.count)c")
    }

    @Test("no history reads as zero, not a missing field")
    func anatomyWithoutHistory() {
        let line = AgentRAGResponder.promptAnatomy(prompt: "USER: hi", history: [], budget: .default)
        #expect(line == "prompt anatomy: 8c · history 0c in 0 turns · rest 8c")
    }

    @Test("traced earlier lines are counted apart from the kept turns")
    func anatomyCountsTheTrace() {
        let history = (1 ... 6).flatMap { n in
            [ChatTurn(role: .user, text: "Fact \(n)."), ChatTurn(role: .assistant, text: "ok")]
        }
        let budget = HistoryWindow.Budget(totalChars: 8000, perTurnChars: 1500, maxTurns: 4, earlierUserChars: 600)
        let replay = HistoryWindow.render(history, budget: budget) ?? ""
        let prompt = "identity\n\n" + replay + "\n\nUSER: hi"
        let line = AgentRAGResponder.promptAnatomy(prompt: prompt, history: history, budget: budget)
        #expect(line.hasSuffix(" in 4 turns · rest \(prompt.count - replay.count)c · earlier 4"))
    }
}
