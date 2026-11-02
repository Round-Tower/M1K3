//
//  ContentFreeReplyTests.swift
//  M1K3ChatTests
//
//  A content-free reply ("Yes. Please.", "No thanks", "Cheers") carries nothing a tool picker can
//  read. On Kev's iPhone (2026-11-02) M1K3 offered to write a story, the user said "Yes. Please.",
//  the gate said tools at p=0.799, and Apple's picker, which sees only the current message, invented
//  web_search "current weather in New York": the story came back with New York's weather in it.
//  A content-free turn is chat, unless it says yes to an offer in M1K3's previous reply: then the
//  trained gate reads the OFFER (no cue lists), and only a tools verdict on it sends the turn to the
//  picker, which reads the offer, not "yes please". The prompts still carry the user's own words.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-02, Confidence 0.8. Prior: Unknown.
//  Review: Kev + claude-opus-5.5, 2026-11-02 — round 3: the cue lists and the agent hand-off are gone (offer
//  detection held 44% on a held-out set); the gate reads `offerText` and the picker and the dispatch's reads
//  take the offer, the prompts the user's words. Thanks and bare praise close, a "later" defers. Confidence 0.8.
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
    let decided = Mutex<[String]>([])
    let local = Mutex<[String]>([])
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

/// The gate as a table: the reply scores tools at the phone's p=0.799 unless told otherwise, and the
/// offer text (anything else the gate is asked about) gets `onOffer`.
private func gate(
    reply: ToolNeedRouter.Verdict = .tools, replyP: Double? = 0.799, onOffer: ToolNeedRouter.Verdict
) -> @Sendable (String, String) -> ToolNeedRouter.Decision {
    { text, question in
        text == question
            ? .init(verdict: reply, probability: replyP)
            : .init(verdict: onOffer, probability: onOffer == .tools ? 0.9 : 0.1)
    }
}

/// One turn through the responder. The gate records what it read, the picker the message it was
/// handed, the search head the text it was asked about.
private func run(
    _ question: String, history: [ChatTurn], pick: ToolPick?, tools: [any AgentTool], calls: Calls,
    provider: Scripted, decide: @escaping @Sendable (String, String) -> ToolNeedRouter.Decision,
    searchHead: Bool = false
) async throws -> String {
    let route = PlainTurnRoute(
        decide: { text in
            calls.decided.withLock { $0.append(text) }
            return decide(text, question)
        },
        instructions: nil,
        pick: { @Sendable message, _ in
            calls.picks.withLock { $0.append(message) }
            return pick
        },
        staysLocal: searchHead ? { @Sendable text in
            calls.local.withLock { $0.append(text) }
            return SearchRouter.Decision(verdict: .web, probability: 0.9)
        } : nil
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

private let lookupOfferText = "Not sure off-hand. Want me to look up who won?"
private let lookupOffer = [
    ChatTurn(role: .user, text: "Who won the Ballon d'Or?"),
    ChatTurn(role: .assistant, text: lookupOfferText),
]

private let searchOffer = [
    ChatTurn(role: .user, text: "Anything on in Cork this weekend?"),
    ChatTurn(
        role: .assistant,
        text: "I don't have live listings. Want me to search for events in Cork this weekend?"
    ),
]

/// The palette every responder test offers: a lookup, a reference and an action.
private func palette(_ calls: Calls) -> [any AgentTool] {
    [
        Recording(name: "web_search", output: "Ousmane Dembélé won.", calls: calls),
        Recording(name: "lookup_fact", output: "a reference entry", calls: calls),
        Recording(name: "propose_todo", output: "added", calls: calls),
    ]
}

private func isPlainTurn(_ prompt: String?) -> Bool {
    prompt?.contains(AgentRAGResponder.plainRules) == true && prompt?.contains("propose_todo") == false
}

private let newYork = ToolPick(tool: "web_search", query: "current weather in New York")

// MARK: - The responder

struct ContentFreeReplyTurnTests {
    @Test("yes to a story offer: the gate reads the offer, says chat, and the picker is never asked")
    func yesToAStoryIsChat() async throws {
        let calls = Calls()
        let provider = Scripted(["Once upon a time, a dragon…"])
        let text = try await run(
            "Yes. Please.", history: storyOffer, pick: newYork, tools: palette(calls), calls: calls,
            provider: provider, decide: gate(onOffer: .chat)
        )
        #expect(calls.decided.withLock { $0 } == [
            "Yes. Please.", "Sorry to hear it! Want me to write you a short story about a dragon?",
        ])
        #expect(calls.picks.withLock { $0 }.isEmpty)
        #expect(calls.log.withLock { $0 }.isEmpty)
        #expect(provider.prompts.count == 1)
        #expect(isPlainTurn(provider.prompts.first))
        #expect(provider.prompts.first?.contains("USER: Yes. Please.") == true)
        #expect(text.contains("dragon"))
    }

    @Test("yes to a lookup offer the gate reads as tools: the picker reads the offer, the prompt the user's words")
    func yesToALookupPicksFromTheOffer() async throws {
        // No ceiling: a chat verdict on the reply itself doesn't matter, the offer's verdict does.
        for (reply, replyP) in [(ToolNeedRouter.Verdict.tools, 0.799), (.chat, 0.12)] {
            let calls = Calls()
            let provider = Scripted(["Ousmane Dembélé won it."])
            _ = try await run(
                "yes please", history: lookupOffer,
                pick: ToolPick(tool: "web_search", query: "Ballon d'Or winner"),
                tools: palette(calls), calls: calls, provider: provider,
                decide: gate(reply: reply, replyP: replyP, onOffer: .tools)
            )
            #expect(calls.picks.withLock { $0 } == [lookupOfferText], "reply verdict \(reply)")
            #expect(calls.log.withLock { $0 } == ["web_search(Ballon d'Or winner)"])
            let prompt = try #require(provider.prompts.first)
            #expect(prompt.contains("USER: yes please"))
            #expect(prompt.contains("Who won the Ballon d'Or?"))
            #expect(prompt.contains(lookupOfferText))
            #expect(prompt.contains("Ousmane Dembélé won."))
        }
    }

    @Test("the dispatch's reads take the offer: the recency correction and the empty-query plan")
    func correctionsReadTheOffer() async throws {
        let calls = Calls()
        let provider = Scripted(["It was Dembélé."])
        let history = [
            ChatTurn(role: .user, text: "Who won the Ballon d'Or?"),
            ChatTurn(role: .assistant, text: "Not sure off-hand. Want me to find out who won this year?"),
        ]
        // lookup_fact on a question about this year goes to the web; the empty query reads the offer.
        _ = try await run(
            "yes please", history: history, pick: ToolPick(tool: "lookup_fact", query: ""),
            tools: palette(calls), calls: calls, provider: provider, decide: gate(onOffer: .tools)
        )
        #expect(calls.log.withLock { $0 } == [
            "web_search(Not sure off-hand. Want me to find out who won this year?)",
        ])
    }

    @Test("the search head reads the offer, not \"yes please\"")
    func searchHeadReadsTheOffer() async throws {
        let calls = Calls()
        let provider = Scripted(["It was Dembélé."])
        let history = [
            ChatTurn(role: .user, text: "Who won the Ballon d'Or?"),
            ChatTurn(role: .assistant, text: "Not sure off-hand. Want me to find out who won?"),
        ]
        _ = try await run(
            "yes please", history: history, pick: ToolPick(tool: "web_search", query: "Ballon d'Or winner"),
            tools: palette(calls), calls: calls, provider: provider, decide: gate(onOffer: .tools), searchHead: true
        )
        #expect(calls.local.withLock { $0 } == ["Not sure off-hand. Want me to find out who won?"])
        #expect(calls.log.withLock { $0 } == ["web_search(Ballon d'Or winner)"])
    }

    @Test("\"Great, thanks\" after a lookup offer closes: chat, the offer is never read, no picker")
    func thanksAfterAnOfferIsChat() async throws {
        let calls = Calls()
        let provider = Scripted(["Any time."])
        _ = try await run(
            "Great, thanks", history: lookupOffer, pick: newYork, tools: palette(calls), calls: calls,
            provider: provider, decide: gate(onOffer: .tools)
        )
        #expect(calls.decided.withLock { $0 } == ["Great, thanks"])
        #expect(calls.picks.withLock { $0 }.isEmpty)
        #expect(isPlainTurn(provider.prompts.first))
    }

    @Test("\"do it later\" defers: chat, no picker")
    func laterIsChat() async throws {
        let calls = Calls()
        let provider = Scripted(["No bother."])
        _ = try await run(
            "do it later", history: lookupOffer, pick: newYork, tools: palette(calls), calls: calls,
            provider: provider, decide: gate(onOffer: .tools)
        )
        #expect(calls.picks.withLock { $0 }.isEmpty)
        #expect(isPlainTurn(provider.prompts.first))
    }

    @Test("\"No, go ahead\" is a yes: the gate reads the offer and the picker gets it")
    func noGoAheadIsAYes() async throws {
        let calls = Calls()
        let provider = Scripted(["Dembélé."])
        _ = try await run(
            "No, go ahead", history: lookupOffer, pick: ToolPick(tool: "web_search", query: "Ballon d'Or winner"),
            tools: palette(calls), calls: calls, provider: provider, decide: gate(onOffer: .tools)
        )
        #expect(calls.picks.withLock { $0 } == [lookupOfferText])
    }

    @Test("no thanks to a search offer is chat: no picker")
    func noThanksIsChat() async throws {
        let calls = Calls()
        let provider = Scripted(["No problem."])
        _ = try await run(
            "No thanks", history: searchOffer, pick: ToolPick(tool: "web_search", query: "events in Cork"),
            tools: palette(calls), calls: calls, provider: provider, decide: gate(onOffer: .tools)
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
            "yes, Cork", history: searchOffer, pick: ToolPick(tool: "web_search", query: "events in Cork"),
            tools: palette(calls), calls: calls, provider: provider, decide: gate(onOffer: .chat)
        )
        #expect(calls.decided.withLock { $0 } == ["yes, Cork"])
        #expect(calls.picks.withLock { $0 } == ["yes, Cork"])
        #expect(calls.log.withLock { $0 } == ["web_search(events in Cork)"])
    }

    @Test("yes please on a fresh chat is chat")
    func freshYesIsChat() async throws {
        let calls = Calls()
        let provider = Scripted(["Happy to help — with what?"])
        _ = try await run(
            "yes please", history: [], pick: ToolPick(tool: "web_search", query: "yes please"),
            tools: palette(calls), calls: calls, provider: provider, decide: gate(onOffer: .tools)
        )
        #expect(calls.picks.withLock { $0 }.isEmpty)
        #expect(provider.prompts.count == 1)
        #expect(isPlainTurn(provider.prompts.first))
    }
}

// MARK: - The policy

struct ContentFreeReplyTests {
    @Test("affirmative replies", arguments: [
        "Yes. Please.", "yes please", "Yeah, go on", "Sure!", "ok", "Okay, do it", "Go ahead", "Sounds good",
        "That sounds great, thanks", "Yes please, Mike", "Absolutely", "Why not?", "Of course", "Continue",
        "Yes I\u{2019}d love that", "yep", "Aye, go on so", "👍", "👍🏽", "🙌", "Oui, s'il vous plaît", "Ja, bitte",
        "Sí, por favor", "Sim", "Tak", "YES", "please do", "mhm", "Uh huh", "uh-huh", "go", "ok go", "Go!",
        // An acceptance word beside a thanks or praise is a yes.
        "Yes, thanks", "Great, yes please", "Perfect, go ahead", "oui, merci", "Lovely, do it", "Sure, cheers",
        "Vale", "Claro", "Sea",
        "I'd love that", "I\u{2019}d love that", "Do that", "Do this", "Do so", "Love it", "Love that", "I would",
        "Let's do it", "Lets do it", "Let's go!", "Tell me", "Sure thing",
        // A go phrase beats a no: "No, go ahead" waves the doubt away (common in Irish English).
        "No, go ahead", "Ah no, go on", "nah go for it", "No no, do it",
    ])
    func affirmative(text: String) {
        #expect(ToolNeedRouter.contentFreeReply(text) == .affirmative)
    }

    @Test("declining replies", arguments: [
        "No thanks", "Nope", "Not now", "No, that's ok", "Nah, I'm good", "Maybe later", "Nein, danke",
        "Non merci", "👎", "no", "Nah, that's grand", "No, please",
        // Not now means not now, whatever go phrase rides with it.
        "do it later", "Go ahead, not now", "Not now, go on", "later", "yes, later",
    ])
    func declining(text: String) {
        #expect(ToolNeedRouter.contentFreeReply(text) == .declining)
    }

    @Test("neutral replies: thanks and bare praise close", arguments: [
        "Thanks", "Thank you!", "Cheers Mike", "ta", "Go raibh maith agat", "Merci beaucoup", "Danke schön",
        "Gracias", "Grazie", "Obrigado", "No worries", "No problem", "Good",
        "Great, thanks", "Perfect", "Cool", "Lovely, thanks", "Grand", "Nice", "Brilliant", "Fine", "Excellent",
        "Awesome", "Great", "Perfect, thank you", "Cool cool",
    ])
    func neutral(text: String) {
        #expect(ToolNeedRouter.contentFreeReply(text) == .neutral)
    }

    @Test("anything with content is not content-free", arguments: [
        "yes, Cork", "Do it again", "more", "next", "another one", "Yes please, and the weather tomorrow",
        "What's the weather?", "", "   ", "😂", "Tell me more", "yes 2", "no, Cork Ireland", "Yes, search it",
        "What time is it?", "Check my calendar", "class", "the sea", "Tell me another", "Let's go again",
        "do the next one", "go home",
    ])
    func notContentFree(text: String) {
        #expect(ToolNeedRouter.contentFreeReply(text) == nil)
    }

    @Test("the offer text: the previous reply's last two sentences, cleaned", arguments: [
        (
            "Sorry to hear it! Want me to write you a short story about a dragon?",
            "Sorry to hear it! Want me to write you a short story about a dragon?"
        ),
        ("I'm bored too. Cork is lovely. Want me to look it up?", "Cork is lovely. Want me to look it up?"),
        ("<think>they want news</think>Do you want me to pull up the news?", "Do you want me to pull up the news?"),
        // A FOLLOWUPS trailer is cut.
        ("Want me to search for showtimes?\nFOLLOWUPS: [\"What's on?\"]", "Want me to search for showtimes?"),
        // A bullet list of links under a sources line is cut, one block or two.
        (
            "The match starts at 8. Should I check the latest team news?\n\nWeb sources:\n• https://example.com/a",
            "The match starts at 8. Should I check the latest team news?"
        ),
        (
            "He was born in 1879. Want me to look up more?\n\nWikipedia sources:\n"
                + "• https://en.wikipedia.org/wiki/Albert_Einstein\n\nWeb sources:\n- https://example.com/b",
            "He was born in 1879. Want me to look up more?"
        ),
        ("Want me to check it?\n\nSources:\n* https://a.example\n* https://b.example", "Want me to check it?"),
        // A prose line that names sources is the reply, not a tail.
        (
            "The river splits at the city.\nThe main sources: the Lee and the Bride.",
            "The river splits at the city. The main sources: the Lee and the Bride."
        ),
        // A sources line followed by more than links is not a tail either.
        (
            "Here's the gist.\n\nWeb sources:\n• https://a.example\nWant me to dig up more?",
            "• https://a.example Want me to dig up more?"
        ),
        // An emoji or a sign-off has no letters to read: the sentences before it are the offer.
        ("Want me to look up showtimes? 🍿", "Want me to look up showtimes?"),
        // Quotes stripped, lines flattened.
        ("He said \u{201C}grand\u{201D}.\nWant me to \"check\"?", "He said grand. Want me to check?"),
    ])
    func offerText(reply: String, offer: String) {
        let history = [ChatTurn(role: .user, text: "hm"), ChatTurn(role: .assistant, text: reply)]
        #expect(ToolNeedRouter.offerText(in: history) == offer)
    }

    @Test("the offer text is capped at 300 characters, keeping its end")
    func offerTextIsCapped() throws {
        let long = String(repeating: "word ", count: 120) + "end. Want me to look it up?"
        let history = [ChatTurn(role: .assistant, text: long)]
        let offer = try #require(ToolNeedRouter.offerText(in: history))
        #expect(offer.count <= 300)
        #expect(offer.hasSuffix("end. Want me to look it up?"))
        #expect(offer.hasPrefix("word "))
    }

    @Test("no offer text without M1K3's last reply")
    func offerNeedsTheLastTurn() {
        #expect(ToolNeedRouter.offerText(in: []) == nil)
        let userLast = [
            ChatTurn(role: .assistant, text: "Want me to search for flights to Lisbon?"),
            ChatTurn(role: .user, text: "hmm"),
        ]
        #expect(ToolNeedRouter.offerText(in: userLast) == nil)
        #expect(ToolNeedRouter.offerText(in: [ChatTurn(role: .assistant, text: "🍿 👍")]) == nil)
        #expect(ToolNeedRouter.offerText(in: [ChatTurn(role: .assistant, text: "<think>hm</think>")]) == nil)
    }
}
