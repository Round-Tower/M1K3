//
//  ContentFreeReplyTests.swift
//  M1K3ChatTests
//
//  A content-free reply ("Yes. Please.", "No thanks", "Cheers") carries nothing a tool picker can
//  read. On Kev's iPhone (2026-11-02) M1K3 offered to write a story, the user said "Yes. Please.",
//  the gate said tools at p=0.799, and Apple's picker, which sees only the current message, invented
//  web_search "current weather in New York": the story came back with New York's weather in it.
//  A content-free turn is chat, unless it says yes to M1K3's own offer to look something up or to
//  act: then it is the AGENT turn, whatever the gate said, which reads the chat and the whole palette
//  and works the query out itself. The picker never reads a content-free turn.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-02, Confidence 0.8. Prior: Unknown.
//  Review: Kev + claude-opus-5.5, 2026-11-02 — redesigned after two adversarial reviews: the offer-scoped
//  picker is gone (its keep rule dropped every "Want me to look it up?" pick and the Mac group head's empty
//  queries); a yes to a lookup or action offer is the agent turn, on a chat verdict too. Confidence 0.8.
//

import Foundation
import M1K3Agent
@testable import M1K3Chat
import M1K3Inference
import M1K3Knowledge
import Synchronization
import Testing

private final class Scripted: InferenceProvider, @unchecked Sendable {
    let name = "content-free-scripted"
    let isAvailable = true
    private let state = Mutex<(responses: [String], prompts: [String])>(([], []))

    init(_ responses: [String]) {
        state.withLock { $0.responses = responses }
    }

    private func next(_ prompt: String) -> String {
        state.withLock {
            $0.prompts.append(prompt)
            return $0.responses.isEmpty ? "" : $0.responses.removeFirst()
        }
    }

    func generate(prompt: String) async throws -> String {
        next(prompt)
    }

    func generateStreaming(prompt: String) -> AsyncStream<String> {
        let response = next(prompt)
        return AsyncStream { continuation in
            if !response.isEmpty { continuation.yield(response) }
            continuation.finish()
        }
    }

    var prompts: [String] {
        state.withLock { $0.prompts }
    }
}

private final class Calls: Sendable {
    let log = Mutex<[String]>([])
    let picks = Mutex<[String]>([])
}

private struct Recording: AgentTool {
    let name: String
    let output: String
    let calls: Calls
    var description: String {
        name
    }

    var parameters: [ToolParameter] {
        [ToolParameter(name: "query", description: "")]
    }

    func execute(input: [String: String]) async throws -> ToolResult {
        calls.log.withLock { $0.append("\(name)(\(input["query"] ?? ""))") }
        return ToolResult(output: output)
    }
}

/// One turn through the responder with the gate's verdict (tools at the phone's p=0.799 unless told
/// otherwise). The picker records the message it was handed and answers `pick`.
private func run(
    _ question: String, history: [ChatTurn], pick: ToolPick?, tools: [any AgentTool],
    calls: Calls, provider: Scripted, verdict: ToolNeedRouter.Verdict = .tools, probability: Double? = 0.799
) async throws -> String {
    let route = PlainTurnRoute(
        decide: { _ in .init(verdict: verdict, probability: probability) },
        instructions: nil,
        pick: { @Sendable message, _ in
            calls.picks.withLock { $0.append(message) }
            return pick
        }
    )
    let responder = try AgentRAGResponder(
        store: KnowledgeStore(), embedder: HashingEmbeddingService(), provider: provider,
        toolsProvider: { tools }, plainRouteProvider: { route }
    )
    var text = ""
    let stream = try await responder.answerStreaming(
        question, images: [], history: history, onActivity: { _ in }
    ).stream
    for await piece in stream {
        text = StreamFold.fold(current: text, chunk: piece)
    }
    return text
}

private let storyOffer = [
    ChatTurn(role: .user, text: "I'm bored."),
    ChatTurn(role: .assistant, text: "Sorry to hear it! Want me to write you a short story about a dragon?"),
]

private let lookupOffer = [
    ChatTurn(role: .user, text: "Who won the Ballon d'Or this year?"),
    ChatTurn(role: .assistant, text: "I'm not sure. Want me to look it up?"),
]

private let todoOffer = [
    ChatTurn(role: .user, text: "I need to ring the plumber about the boiler."),
    ChatTurn(role: .assistant, text: "Good plan. Want me to add that as a todo?"),
]

private let searchOffer = [
    ChatTurn(role: .user, text: "Anything on in Cork this weekend?"),
    ChatTurn(
        role: .assistant,
        text: "I don't have live listings. Want me to search for events in Cork this weekend?"
    ),
]

/// The palette every responder test offers: a lookup and an action, neither named by the plain rules.
private func palette(_ calls: Calls) -> [any AgentTool] {
    [
        Recording(name: "web_search", output: "New York: 12°C", calls: calls),
        Recording(name: "propose_todo", output: "added", calls: calls),
    ]
}

/// The agent turn's prompt lists the palette and carries the chat; a plain turn's carries the plain rules.
private func isAgentTurn(_ prompt: String?) -> Bool {
    guard let prompt else { return false }
    return prompt.contains("propose_todo") && !prompt.contains(AgentRAGResponder.plainRules)
}

private func isPlainTurn(_ prompt: String?) -> Bool {
    prompt?.contains(AgentRAGResponder.plainRules) == true && prompt?.contains("propose_todo") == false
}

// MARK: - The responder

struct ContentFreeReplyTurnTests {
    @Test("yes to a story offer is chat: the picker is never asked, one plain generation answers")
    func yesToAStoryIsChat() async throws {
        let calls = Calls()
        let provider = Scripted(["Once upon a time, a dragon…"])
        let text = try await run(
            "Yes. Please.", history: storyOffer,
            pick: ToolPick(tool: "web_search", query: "current weather in New York"),
            tools: palette(calls), calls: calls, provider: provider
        )
        #expect(calls.picks.withLock { $0 }.isEmpty)
        #expect(calls.log.withLock { $0 }.isEmpty)
        #expect(provider.prompts.count == 1)
        #expect(isPlainTurn(provider.prompts.first))
        #expect(text.contains("dragon"))
    }

    @Test("yes to a lookup offer is the agent turn: the picker is never asked, the agent reads the chat")
    func yesToALookupIsTheAgent() async throws {
        for verdict in [ToolNeedRouter.Verdict.tools, .chat] {
            let calls = Calls()
            let provider = Scripted(["CONCLUSION: Ousmane Dembélé."])
            _ = try await run(
                "yes please", history: lookupOffer,
                pick: ToolPick(tool: "web_search", query: "current weather in New York"),
                tools: palette(calls), calls: calls, provider: provider,
                verdict: verdict, probability: verdict == .tools ? 0.799 : 0.12
            )
            #expect(calls.picks.withLock { $0 }.isEmpty, "the picker read a content-free yes (\(verdict))")
            let prompt = provider.prompts.first
            #expect(isAgentTurn(prompt), "no agent turn on a \(verdict) verdict")
            // The agent reads the chat: the question and the offer it says yes to.
            #expect(prompt?.contains("Ballon d'Or") == true)
            #expect(prompt?.contains("Want me to look it up?") == true)
        }
    }

    @Test("yes to an action offer is the agent turn")
    func yesToAnActionIsTheAgent() async throws {
        let calls = Calls()
        let provider = Scripted(["CONCLUSION: Added."])
        _ = try await run(
            "do it", history: todoOffer, pick: ToolPick(tool: "web_search", query: "do it"),
            tools: palette(calls), calls: calls, provider: provider
        )
        #expect(calls.picks.withLock { $0 }.isEmpty)
        #expect(isAgentTurn(provider.prompts.first))
    }

    @Test("\"No, go ahead\" to a lookup offer is a yes: the agent turn")
    func noGoAheadIsAYes() async throws {
        let calls = Calls()
        let provider = Scripted(["CONCLUSION: done"])
        _ = try await run(
            "No, go ahead", history: lookupOffer, pick: nil,
            tools: palette(calls), calls: calls, provider: provider
        )
        #expect(calls.picks.withLock { $0 }.isEmpty)
        #expect(isAgentTurn(provider.prompts.first))
    }

    @Test("no thanks to a lookup offer is chat: no picker, no agent")
    func noThanksIsChat() async throws {
        let calls = Calls()
        let provider = Scripted(["No problem."])
        _ = try await run(
            "No thanks", history: searchOffer,
            pick: ToolPick(tool: "web_search", query: "events in Cork"),
            tools: palette(calls), calls: calls, provider: provider
        )
        #expect(calls.picks.withLock { $0 }.isEmpty)
        #expect(calls.log.withLock { $0 }.isEmpty)
        #expect(provider.prompts.count == 1)
        #expect(isPlainTurn(provider.prompts.first))
    }

    @Test("a reply with content keeps today's path: the picker gets the user's words unchanged")
    func replyWithContentIsUnchanged() async throws {
        let calls = Calls()
        let provider = Scripted(["Here's what's on."])
        _ = try await run(
            "yes, Cork", history: searchOffer,
            pick: ToolPick(tool: "web_search", query: "events in Cork"),
            tools: palette(calls), calls: calls, provider: provider
        )
        #expect(calls.picks.withLock { $0 } == ["yes, Cork"])
        #expect(calls.log.withLock { $0 } == ["web_search(events in Cork)"])
    }

    @Test("yes please on a fresh chat is chat")
    func freshYesIsChat() async throws {
        let calls = Calls()
        let provider = Scripted(["Happy to help — with what?"])
        _ = try await run(
            "yes please", history: [],
            pick: ToolPick(tool: "web_search", query: "yes please"),
            tools: palette(calls), calls: calls, provider: provider
        )
        #expect(calls.picks.withLock { $0 }.isEmpty)
        #expect(provider.prompts.count == 1)
        #expect(isPlainTurn(provider.prompts.first))
    }

    /// Accepted cost: "read" is a lookup cue (read the document, read the page), so a yes to "read you a
    /// story" is an agent turn. That costs speed (the palette and the loop), not a wrong answer: the agent
    /// reads the chat, where the picker read only "Yes. Please." and invented a search.
    @Test("yes to \"read you a bedtime story\" is the agent turn (accepted: slower, not wrong)")
    func readAStoryIsTheAgent() async throws {
        let calls = Calls()
        let provider = Scripted(["CONCLUSION: Once upon a time…"])
        let history = [
            ChatTurn(role: .user, text: "Can't sleep."),
            ChatTurn(role: .assistant, text: "Poor you. Want me to read you a bedtime story?"),
        ]
        _ = try await run(
            "Yes. Please.", history: history, pick: ToolPick(tool: "web_search", query: "current weather in New York"),
            tools: palette(calls), calls: calls, provider: provider
        )
        #expect(calls.picks.withLock { $0 }.isEmpty)
        #expect(isAgentTurn(provider.prompts.first))
    }
}

// MARK: - The policy

struct ContentFreeReplyTests {
    @Test("affirmative replies", arguments: [
        "Yes. Please.", "yes please", "Yeah, go on", "Sure!", "ok", "Okay, do it", "Go ahead", "Sounds good",
        "That sounds great, thanks", "Yes please, Mike", "Absolutely", "Why not?", "Of course", "Continue",
        "Yes I\u{2019}d love that", "yep", "Aye, go on so", "👍", "👍🏽", "Oui, s'il vous plaît", "Ja, bitte",
        "Sí, por favor", "Sim", "Tak", "Lovely, thanks", "Grand", "Brilliant", "YES", "please do",
        // Filler-only yeses (adversarial review 2026-11-02): these had read as neutral.
        "I'd love that", "I\u{2019}d love that", "Do that", "Do this", "Do so", "Love it", "Love that", "I would",
        "Let's do it", "Lets do it", "Let's go!", "Tell me", "Sure thing",
        // A go phrase beats a no: "No, go ahead" waves the doubt away (common in Irish English).
        "No, go ahead", "Ah no, go on", "nah go for it", "No no, do it",
        // Irish "'Sea" (is ea, "it is"): a yes on its own.
        "Sea",
    ])
    func affirmative(text: String) {
        #expect(ToolNeedRouter.contentFreeReply(text) == .affirmative)
    }

    @Test("declining replies", arguments: [
        "No thanks", "Nope", "Not now", "No, that's ok", "Nah, I'm good", "Maybe later", "Nein, danke",
        "Non merci", "👎", "no", "Nah, that's grand", "No, please",
    ])
    func declining(text: String) {
        #expect(ToolNeedRouter.contentFreeReply(text) == .declining)
    }

    @Test("neutral replies", arguments: [
        "Thanks", "Thank you!", "Cheers Mike", "ta", "Go raibh maith agat", "Merci beaucoup", "Danke schön",
        "Gracias", "No worries", "No problem", "Good",
    ])
    func neutral(text: String) {
        #expect(ToolNeedRouter.contentFreeReply(text) == .neutral)
    }

    @Test("anything with content is not content-free", arguments: [
        "yes, Cork", "Do it again", "more", "next", "another one", "Yes please, and the weather tomorrow",
        "What's the weather?", "", "   ", "😂", "Tell me more", "yes 2", "no, Cork Ireland", "Yes, search it",
        "What time is it?", "Check my calendar", "class", "the sea", "Tell me another", "Let's go again",
        "do the next one",
    ])
    func notContentFree(text: String) {
        #expect(ToolNeedRouter.contentFreeReply(text) == nil)
    }

    @Test("the reply offers a tool: the offer sentence", arguments: [
        (
            "I don't have live data. Want me to look up the forecast for Cork?",
            "Want me to look up the forecast for Cork?"
        ),
        ("Shall I search for flights to Lisbon?", "Shall I search for flights to Lisbon?"),
        ("Good question. I can check the latest scores if you like.", "I can check the latest scores if you like."),
        ("Would you like me to find a recipe online?", "Would you like me to find a recipe online?"),
        ("<think>they want news</think>Do you want me to pull up the news?", "Do you want me to pull up the news?"),
        ("I'm not sure. Want me to look it up?", "Want me to look it up?"),
        ("Should I find out when it opens?", "Should I find out when it opens?"),
        ("Happy to dig into it if you want.", "Happy to dig into it if you want."),
        // Action offers.
        ("Good plan. Want me to add that as a todo?", "Want me to add that as a todo?"),
        ("Shall I set a timer for ten minutes?", "Shall I set a timer for ten minutes?"),
        ("Want me to open the Cork Jazz site?", "Want me to open the Cork Jazz site?"),
        ("Should I put it on your calendar?", "Should I put it on your calendar?"),
        ("Want me to remind you tomorrow?", "Want me to remind you tomorrow?"),
        // Accepted: "read" is a lookup cue, so a story read aloud counts (an agent turn, slower, not wrong).
        ("Poor you. Want me to read you a bedtime story?", "Want me to read you a bedtime story?"),
        // Every sources tail is cut.
        (
            "The match starts at 8. Should I check the latest team news?\n\nWeb sources:\n• https://example.com/a",
            "Should I check the latest team news?"
        ),
        (
            "He was born in 1879. Want me to look up more about his early life?\n\nWikipedia sources:\n"
                + "• https://en.wikipedia.org/wiki/Albert_Einstein",
            "Want me to look up more about his early life?"
        ),
        ("Want me to check it?\n\nSources:\n• a\n• b", "Want me to check it?"),
        ("Shall I fetch the page?\n\nFact sources:\n• https://example.com", "Shall I fetch the page?"),
        // A FOLLOWUPS trailer is cut.
        ("Want me to search for showtimes?\nFOLLOWUPS: [\"What's on?\"]", "Want me to search for showtimes?"),
        // An emoji, a sign-off or an abbreviation split after the offer doesn't hide it.
        ("Want me to look up showtimes? 🍿", "Want me to look up showtimes?"),
        ("Shall I check the latest? Just say the word!", "Shall I check the latest?"),
        ("Want me to look up events for St. Patrick's Day?", "Want me to look up events for St."),
    ])
    func offers(reply: String, offer: String) {
        let history = [ChatTurn(role: .user, text: "hm"), ChatTurn(role: .assistant, text: reply)]
        #expect(ToolNeedRouter.toolOffer(in: history) == offer)
    }

    @Test("no tool offer", arguments: [
        "Want me to write you a short story about a dragon?",
        "Shall I tell you a joke?",
        "I could look that up last time.",
        "Here's what I found.\n\nWeb sources:\n• https://example.com/a",
        "Cork is lovely in October.",
        "Want me to keep going?",
        "I can walk you through how it works if you fancy it.",
        // The offer is three sentences back: only the last two count.
        "Want me to look it up? Either way, it's a fine question. Cork is lovely in October.",
        "Want me to explain it in plain English? No jargon, I promise.",
    ])
    func noOffer(reply: String) {
        let history = [ChatTurn(role: .user, text: "hm"), ChatTurn(role: .assistant, text: reply)]
        #expect(ToolNeedRouter.toolOffer(in: history) == nil)
    }

    @Test("only the previous assistant reply can carry the offer")
    func offerNeedsTheLastTurn() {
        #expect(ToolNeedRouter.toolOffer(in: []) == nil)
        let userLast = [
            ChatTurn(role: .assistant, text: "Want me to search for flights to Lisbon?"),
            ChatTurn(role: .user, text: "hmm"),
        ]
        #expect(ToolNeedRouter.toolOffer(in: userLast) == nil)
    }
}
