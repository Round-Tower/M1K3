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
//  detection held 44% on a held-out set); the gate reads `offerText` (only when the reply offers), the picker and
//  the dispatch's reads take the offer as a request, the prompts the user's words. Pinned from the round 3
//  review: acknowledgements after an answer stay chat, an empty-query pick on a yes runs no tool, the search
//  head's guard skips M1K3's content sentence, retrieval reads the offer (#712), sources tails in every shape.
//  Confidence 0.8.
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
    searchHead: Bool = false, store: KnowledgeStore? = nil
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
        store: store ?? KnowledgeStore(), embedder: HashingEmbeddingService(), provider: provider,
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
            // The picker reads the offer as a request: "Want me to look up who won?" → "look up who won".
            #expect(calls.picks.withLock { $0 } == ["look up who won"], "reply verdict \(reply)")
            #expect(calls.log.withLock { $0 } == ["web_search(Ballon d'Or winner)"])
            let prompt = try #require(provider.prompts.first)
            #expect(prompt.contains("USER: yes please"))
            #expect(prompt.contains("Who won the Ballon d'Or?"))
            #expect(prompt.contains(lookupOfferText))
            #expect(prompt.contains("Ousmane Dembélé won."))
        }
    }

    @Test("the recency correction reads the offer's request: a this-year lookup goes to the web")
    func correctionsReadTheOffer() async throws {
        let calls = Calls()
        let provider = Scripted(["It was Dembélé."])
        let history = [
            ChatTurn(role: .user, text: "Who won the Ballon d'Or?"),
            ChatTurn(role: .assistant, text: "Not sure off-hand. Want me to find out who won this year?"),
        ]
        _ = try await run(
            "yes please", history: history, pick: ToolPick(tool: "lookup_fact", query: "Ballon d'Or winner"),
            tools: palette(calls), calls: calls, provider: provider, decide: gate(onOffer: .tools)
        )
        #expect(calls.picks.withLock { $0 } == ["find out who won this year"])
        #expect(calls.log.withLock { $0 } == ["web_search(Ballon d'Or winner)"])
    }

    /// Round 3 review (high): an empty-query pick planned with the offer text sent M1K3's own words, which
    /// may be grounded in private notes ("Your appointment with Dr Byrne about the biopsy…"), to DuckDuckGo
    /// or Wikipedia. On a yes to an offer, a pick that would read the question is no pick: the agent turn
    /// answers, with the chat in hand. A chain link that would read it is dropped.
    @Test("an empty-query pick on a yes to an offer is no pick: M1K3's words never become a query")
    func emptyQueryOnAnOfferIsNoPick() async throws {
        let offerText = "Your appointment with Dr Byrne about the biopsy is Thursday at 3. "
            + "Want me to check the traffic then?"
        let history = [
            ChatTurn(role: .user, text: "When's my appointment?"), ChatTurn(role: .assistant, text: offerText),
        ]
        let picks = [
            ToolPick(tool: "web_search", query: ""), ToolPick(tool: "lookup_fact", query: "  "),
            ToolPick(tool: "web_search", query: "traffic Thursday", then: [ToolPick(tool: "lookup_fact", query: "")]),
        ]
        for pick in picks {
            let calls = Calls()
            let provider = Scripted(["Traffic looks light."])
            _ = try await run(
                "yes", history: history, pick: pick, tools: palette(calls), calls: calls, provider: provider,
                decide: gate(onOffer: .tools)
            )
            let log = calls.log.withLock { $0 }
            #expect(!log.contains { $0.contains("Byrne") || $0.contains("biopsy") || $0.contains("traffic then") })
            #expect(log.allSatisfy { !$0.hasSuffix("()") })
            if pick.query.trimmingCharacters(in: .whitespaces).isEmpty {
                #expect(log.isEmpty, "\(pick.tool): no tool ran")
                // The nil-pick path: the agent turn, with the palette and the chat.
                let prompt = try #require(provider.prompts.first)
                #expect(prompt.contains("propose_todo"))
                #expect(prompt.contains("Dr Byrne"))
            } else {
                #expect(log == ["web_search(traffic Thursday)"], "the empty chain link is dropped")
            }
        }
    }

    @Test("the search head reads the offer's request, not \"yes please\"")
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
        #expect(calls.local.withLock { $0 } == ["find out who won"])
        #expect(calls.log.withLock { $0 } == ["web_search(Ballon d'Or winner)"])
    }

    /// Round 3 review (medium): the guard ("the user asked for the web in words") read M1K3's content
    /// sentence too, so its "latest" skipped the #713 veto. The guard reads the offer's own ask only.
    @Test("the search head's guard reads the offer's ask, never M1K3's content sentence")
    func searchGuardSkipsTheContentSentence() async throws {
        let calls = Calls()
        let provider = Scripted(["Here's the story of it."])
        let history = [
            ChatTurn(role: .user, text: "When did the last Harry Potter book come out?"),
            ChatTurn(
                role: .assistant, text: "The latest Harry Potter book came out in 2007. Want me to tell you about it?"
            ),
        ]
        _ = try await run(
            "Sure", history: history, pick: ToolPick(tool: "web_search", query: "Harry Potter"),
            tools: palette(calls), calls: calls, provider: provider, decide: gate(onOffer: .tools), searchHead: true
        )
        #expect(calls.local.withLock { $0 }.count == 1, "the head is asked: \"latest\" was M1K3's word")
    }

    @Test("an acknowledgement after an answer that offered nothing is chat: the answer is never re-run")
    func ackAfterAnAnswerIsChat() async throws {
        let weather = [
            ChatTurn(role: .user, text: "Weather in Cork?"),
            ChatTurn(
                role: .assistant, text: "It's 12 degrees and raining in Cork today. Expect showers into the evening."
            ),
        ]
        for ack in ["Ok, thanks", "ok", "Okay, thank you", "alright", "Sure, cheers", "👍", "That's ok"] {
            let calls = Calls()
            let provider = Scripted(["You're welcome."])
            _ = try await run(
                ack, history: weather, pick: ToolPick(tool: "web_search", query: "weather Cork"),
                tools: palette(calls), calls: calls, provider: provider, decide: gate(onOffer: .tools)
            )
            #expect(calls.decided.withLock { $0 } == [ack], "\(ack): only the user's words are scored")
            #expect(calls.picks.withLock { $0 }.isEmpty, "\(ack)")
            #expect(calls.log.withLock { $0 }.isEmpty, "\(ack)")
            #expect(isPlainTurn(provider.prompts.first), "\(ack)")
        }
    }

    /// Round 3 review (medium): retrieval ran on "yes please", so #712's document correction never saw
    /// the manual and Wikipedia answered the user's own torque question. On a yes to an offer, retrieval
    /// reads the offer's request.
    @Test("a yes to an offer retrieves on the offer: the user's manual answers, no lookup leaves the device")
    func yesRetrievesOnTheOffer() async throws {
        let store = try KnowledgeStore()
        try await DocumentIngester(store: store, embedder: HashingEmbeddingService()).ingest(
            title: "Trailer Service Manual",
            pages: [DocumentPage(
                pageNumber: 1,
                text: "4 Hubs\nThe hub nuts on the trailer axle take 145 Nm of torque, tightened in a star pattern."
            )]
        )
        let history = [
            ChatTurn(role: .user, text: "I'm doing the trailer's wheels today."),
            ChatTurn(
                role: .assistant,
                text: "Good luck! Want me to look up the torque for the hub nuts on the trailer axle?"
            ),
        ]
        let calls = Calls()
        let provider = Scripted(["145 Nm, in a star pattern."])
        _ = try await run(
            "yes please", history: history, pick: ToolPick(tool: "lookup_fact", query: "hub nut torque"),
            tools: palette(calls), calls: calls, provider: provider, decide: gate(onOffer: .tools), store: store
        )
        #expect(calls.log.withLock { $0 }.isEmpty, "no lookup leaves the device")
        let prompt = try #require(provider.prompts.first)
        #expect(prompt.contains("145 Nm"), "the manual's chunk grounds the answer")
        #expect(prompt.contains(AgentRAGResponder.plainRules))
        #expect(prompt.contains("USER: yes please"))
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
        #expect(calls.picks.withLock { $0 } == ["look up who won"])
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
        "Yes, thanks", "Great, yes please", "Perfect, go ahead", "oui, merci", "Lovely, do it",
        // A conditional plus praise is a yes, and so is liking it.
        "That would be great", "That'd be lovely", "That\u{2019}d be brilliant", "That sounds lovely",
        "Would be great", "I'd like that", "I would like that", "I'd really like that",
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
        "Non merci", "👎", "no", "Nah, that's grand", "No, please", "No, that's fine",
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
        // A weak yes beside a thanks is an acknowledgement, not an acceptance (round 3 review, high).
        "ok thanks", "Ok, thanks", "Okay, thank you", "Sure, cheers", "k thanks", "Alright, cheers", "fine thanks",
        "Sure thing, thanks", "OK ta",
        // "That's ok" declines or closes in Irish and British English.
        "That's ok", "It's ok", "It's okay", "It's alright", "That's alright", "That's fine", "It's fine",
        "You're grand", "You\u{2019}re grand, thanks", "That's ok, thanks",
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
            "The main sources: the Lee and the Bride.\nWant me to map them?",
            "The main sources: the Lee and the Bride. Want me to map them?"
        ),
        // Model-written tails in every shape the speech lane cuts.
        ("Want me to check it?\n\n**Sources:**\n- https://a.example", "Want me to check it?"),
        ("Want me to check it?\n\n## Sources\n1. https://a.example\n2. https://b.example", "Want me to check it?"),
        ("Want me to check it?\n\nSource:\n[1] The Irish Times, 2026", "Want me to check it?"),
        ("Want me to check it?\n\nSources: [1] a.example, [2] b.example", "Want me to check it?"),
        ("Want me to check it?\n\n*Web sources:*\n• https://a.example", "Want me to check it?"),
        // An offer that is not a question: "I can … if you like", "happy to … just say".
        (
            "Cork has a few. I can look up the listings if you like.",
            "Cork has a few. I can look up the listings if you like."
        ),
        ("That's the gist. Happy to dig into it, just say.", "That's the gist. Happy to dig into it, just say."),
        // A question with a closing quote or an emoji after it.
        ("That's grand. Want me to look it up?\u{201D}", "That's grand. Want me to look it up?"),
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

    /// Round 3 review (high): offerText took the last two sentences of ANY reply, so "Ok, thanks" after a
    /// weather answer re-ran the weather search on the answer's own text.
    @Test("no offer text when the reply ends in statements: an answer is not an offer", arguments: [
        "It's 12 degrees and raining in Cork today. Expect showers into the evening.",
        "It's 3:42 PM on Monday, November 2.",
        "Do you know what? The Eiffel Tower is 330 metres tall. It was finished in 1889.",
        "The river splits at the city.\nThe main sources: the Lee and the Bride.",
        "I could be wrong about that. It was 2007.",
    ])
    func answerIsNoOffer(reply: String) {
        #expect(ToolNeedRouter.offerText(in: [ChatTurn(role: .assistant, text: reply)]) == nil)
    }

    @Test("the offer's request: the offer form stripped, an imperative the picker can read", arguments: [
        (
            "Sorry to hear it! Want me to write you a short story about a dragon?",
            "write me a short story about a dragon"
        ),
        ("Not sure. Want me to look it up?", "Not sure. look it up"),
        ("Not sure off-hand. Want me to look up who won?", "look up who won"),
        ("I don't have live listings. Do you want me to search for events in Cork?", "search for events in Cork"),
        ("Shall I check the forecast for Kinsale?", "check the forecast for Kinsale"),
        ("Should I pull up the news?", "pull up the news"),
        ("Would you like me to open the BBC website?", "open the BBC website"),
        ("Would it help if I searched for flights to Lisbon?", "searched for flights to Lisbon"),
        ("Cork has a few. I can look up the listings if you like.", "look up the listings"),
        ("Cork has a few. I could check what\u{2019}s on if you want.", "check what's on"),
        ("That's the gist. Happy to dig into it, just say.", "That's the gist. dig into it"),
        ("Fancy me finding a recipe for brown bread?", "finding a recipe for brown bread"),
        ("I don't know. Or want me to check what you decided about the embedder?",
         "check what I decided about the embedder"),
        ("Your calendar is clear. Want me to check your reminders too?", "check my reminders too"),
        // No noun phrase of its own: the sentence before it carries the topic.
        ("The latest Harry Potter book came out in 2007. Want me to tell you about it?",
         "The latest Harry Potter book came out in 2007. tell me about it"),
        // A link M1K3 echoed never reaches the picker.
        ("• https://a.example Want me to dig up more?", "dig up more"),
        // A question with no offer form is read as it stands.
        ("Cork is lovely. Interested in the full history of the city?", "Interested in the full history of the city"),
    ])
    func offerRequest(offer: String, request: String) {
        #expect(ToolNeedRouter.offerRequest(offer) == request)
    }

    @Test("the offer's ask: the offer sentence alone, for the search head's guard", arguments: [
        ("The latest Harry Potter book came out in 2007. Want me to tell you about it?", "tell me about it"),
        ("Not sure. Want me to search for it?", "search for it"),
        (
            "Sorry to hear it! Want me to write you a short story about a dragon?",
            "write me a short story about a dragon"
        ),
    ])
    func offerAsk(offer: String, ask: String) {
        #expect(ToolNeedRouter.offerAsk(offer) == ask)
        #expect(ToolDispatch.asksForTheWeb(ToolNeedRouter.offerAsk(offer)) == ask.contains("search"))
    }

    @Test("the request is capped at 300 characters, keeping its end")
    func offerRequestIsCapped() {
        let long = String(repeating: "word ", count: 120) + "end. Want me to look it up?"
        let request = ToolNeedRouter.offerRequest(long)
        #expect(request.count <= 300)
        #expect(request.hasSuffix("end. look it up"))
    }

    /// The correctors key on the user's voice; the request is in it, so they work on a yes.
    @Test("the correctors read the request: an offer to open a site opens it, a personal one reads the notes")
    func correctorsWorkOnTheRequest() {
        let palette: [any AgentTool] = [
            Recording(name: "web_search", output: "", calls: Calls()),
            Recording(name: "search_knowledge", output: "", calls: Calls()),
        ]
        let open = ToolNeedRouter.offerRequest("Would you like me to open the BBC website?")
        let bbc = ToolPick(tool: "web_search", query: "BBC")
        let opened = ToolDispatch.corrected(bbc, palette: palette, question: open)
        #expect(opened.tool == ToolPick.action)
        let personal = ToolNeedRouter.offerRequest("Not sure. Want me to check what you decided about the embedder?")
        let pick = ToolDispatch.corrected(
            ToolPick(tool: "web_search", query: "embedder decision"), palette: palette, question: personal
        )
        #expect(pick.tool == "search_knowledge")
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
