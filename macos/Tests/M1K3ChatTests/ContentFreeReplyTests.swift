//
//  ContentFreeReplyTests.swift
//  M1K3ChatTests
//
//  A content-free reply ("Yes. Please.", "No thanks", "Cheers") carries nothing a tool picker can
//  read. On Kev's iPhone (2026-11-02) M1K3 offered to write a story, the user said "Yes. Please.",
//  the gate said tools at p=0.799, and Apple's picker, which sees only the current message, invented
//  web_search "current weather in New York": the story came back with New York's weather in it.
//  A content-free turn is chat, unless it says yes to M1K3's own offer to look something up; then
//  the picker reads the offer, and its pick is kept only when it is about what was offered.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-02, Confidence 0.8. Prior: Unknown.
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

/// One turn through the responder with a tools verdict at the phone's p=0.799. The picker records
/// the message it was handed and answers `pick`.
private func run(
    _ question: String, history: [ChatTurn], pick: ToolPick?, tools: [any AgentTool],
    calls: Calls, provider: Scripted
) async throws -> String {
    let route = PlainTurnRoute(
        decide: { _ in .init(verdict: .tools, probability: 0.799) },
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

private let searchOffer = [
    ChatTurn(role: .user, text: "Anything on in Cork this weekend?"),
    ChatTurn(
        role: .assistant,
        text: "I don't have live listings. Want me to search for events in Cork this weekend?"
    ),
]

// MARK: - The responder

struct ContentFreeReplyTurnTests {
    @Test("yes to a story offer is chat: the picker is never asked, one plain generation answers")
    func yesToAStoryIsChat() async throws {
        let calls = Calls()
        let provider = Scripted(["Once upon a time, a dragon…"])
        let web = Recording(name: "web_search", output: "New York: 12°C", calls: calls)
        let text = try await run(
            "Yes. Please.", history: storyOffer,
            pick: ToolPick(tool: "web_search", query: "current weather in New York"),
            tools: [web], calls: calls, provider: provider
        )
        #expect(calls.picks.withLock { $0 }.isEmpty)
        #expect(calls.log.withLock { $0 }.isEmpty)
        #expect(provider.prompts.count == 1)
        #expect(text.contains("dragon"))
    }

    @Test("yes to a lookup offer: the picker reads the offer and the search runs")
    func yesToALookupRunsIt() async throws {
        let calls = Calls()
        let provider = Scripted(["There's a jazz festival on."])
        let web = Recording(name: "web_search", output: "Cork Jazz Festival — https://example.com/jazz", calls: calls)
        _ = try await run(
            "yes please", history: searchOffer,
            pick: ToolPick(tool: "web_search", query: "events in Cork this weekend"),
            tools: [web], calls: calls, provider: provider
        )
        let messages = calls.picks.withLock { $0 }
        #expect(messages.count == 1)
        #expect(messages.first?.contains("search for events in Cork this weekend") == true)
        #expect(messages.first?.hasSuffix("yes please") == true)
        #expect(calls.log.withLock { $0 } == ["web_search(events in Cork this weekend)"])
        // Downstream still reads the user's own words.
        #expect(provider.prompts.count == 1)
        #expect(provider.prompts.first?.contains("yes please") == true)
    }

    @Test("yes to a lookup offer, but the pick is about something else: no tool runs, a plain turn answers")
    func unrelatedPickIsDropped() async throws {
        let calls = Calls()
        let provider = Scripted(["Let me know what you're into."])
        let web = Recording(name: "web_search", output: "New York: 12°C", calls: calls)
        _ = try await run(
            "Yes. Please.", history: searchOffer,
            pick: ToolPick(tool: "web_search", query: "current weather in New York"),
            tools: [web], calls: calls, provider: provider
        )
        #expect(calls.picks.withLock { $0 }.count == 1)
        #expect(calls.log.withLock { $0 }.isEmpty)
        #expect(provider.prompts.count == 1)
        #expect(provider.prompts.first?.contains("New York") == false)
    }

    @Test("no thanks to a lookup offer never asks the picker")
    func noThanksSkipsThePicker() async throws {
        let calls = Calls()
        let provider = Scripted(["No problem."])
        let web = Recording(name: "web_search", output: "x", calls: calls)
        _ = try await run(
            "No thanks", history: searchOffer,
            pick: ToolPick(tool: "web_search", query: "events in Cork"),
            tools: [web], calls: calls, provider: provider
        )
        #expect(calls.picks.withLock { $0 }.isEmpty)
        #expect(calls.log.withLock { $0 }.isEmpty)
        #expect(provider.prompts.count == 1)
    }

    @Test("a reply with content keeps today's path: the picker gets the user's words unchanged")
    func replyWithContentIsUnchanged() async throws {
        let calls = Calls()
        let provider = Scripted(["Here's what's on."])
        let web = Recording(name: "web_search", output: "x", calls: calls)
        _ = try await run(
            "yes, Cork", history: searchOffer,
            pick: ToolPick(tool: "web_search", query: "events in Cork"),
            tools: [web], calls: calls, provider: provider
        )
        #expect(calls.picks.withLock { $0 } == ["yes, Cork"])
        #expect(calls.log.withLock { $0 } == ["web_search(events in Cork)"])
    }

    @Test("yes please on a fresh chat is chat")
    func freshYesIsChat() async throws {
        let calls = Calls()
        let provider = Scripted(["Happy to help — with what?"])
        let web = Recording(name: "web_search", output: "x", calls: calls)
        _ = try await run(
            "yes please", history: [],
            pick: ToolPick(tool: "web_search", query: "yes please"),
            tools: [web], calls: calls, provider: provider
        )
        #expect(calls.picks.withLock { $0 }.isEmpty)
        #expect(provider.prompts.count == 1)
    }

    @Test("yes to a calendar offer runs the calendar peek; a different device read is dropped")
    func deviceOffer() async throws {
        let history = [
            ChatTurn(role: .user, text: "Am I free tomorrow?"),
            ChatTurn(role: .assistant, text: "I'm not sure yet. Shall I check your calendar for tomorrow?"),
        ]
        let calls = Calls()
        let calendar = Recording(name: "calendar_peek", output: "10:00 Dentist", calls: calls)
        let clock = Recording(name: "datetime", output: "Monday", calls: calls)
        _ = try await run(
            "Yep", history: history, pick: ToolPick(tool: "calendar_peek", query: ""),
            tools: [calendar, clock], calls: calls, provider: Scripted(["You've the dentist at ten."])
        )
        // A no-query read gets the user's words, as every dispatched device read does.
        #expect(calls.log.withLock { $0 } == ["calendar_peek(Yep)"])

        let dropped = Calls()
        _ = try await run(
            "Yep", history: history, pick: ToolPick(tool: "datetime", query: ""),
            tools: [calendar, clock], calls: dropped, provider: Scripted(["Hmm."])
        )
        #expect(dropped.log.withLock { $0 }.isEmpty)
    }
}

// MARK: - The policy

struct ContentFreeReplyTests {
    @Test("affirmative replies", arguments: [
        "Yes. Please.", "yes please", "Yeah, go on", "Sure!", "ok", "Okay, do it", "Go ahead", "Sounds good",
        "That sounds great, thanks", "Yes please, Mike", "Absolutely", "Why not?", "Of course", "Continue",
        "Yes I\u{2019}d love that", "yep", "Aye, go on so", "👍", "👍🏽", "Oui, s'il vous plaît", "Ja, bitte",
        "Sí, por favor", "Sim", "Tak", "Lovely, thanks", "Grand", "Brilliant", "YES", "please do",
    ])
    func affirmative(text: String) {
        #expect(ToolNeedRouter.contentFreeReply(text) == .affirmative)
    }

    @Test("declining replies", arguments: [
        "No thanks", "Nope", "Not now", "No, that's ok", "Nah, I'm good", "Maybe later", "Nein, danke",
        "Non merci", "👎", "no",
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
        "What time is it?", "Check my calendar",
    ])
    func notContentFree(text: String) {
        #expect(ToolNeedRouter.contentFreeReply(text) == nil)
    }

    @Test("the last sentence offers a lookup", arguments: [
        (
            "I don't have live data. Want me to look up the forecast for Cork?",
            "Want me to look up the forecast for Cork?"
        ),
        ("Shall I search for flights to Lisbon?", "Shall I search for flights to Lisbon?"),
        ("Good question. I can check the latest scores if you like.", "I can check the latest scores if you like."),
        ("Would you like me to find a recipe online?", "Would you like me to find a recipe online?"),
        ("<think>they want news</think>Do you want me to pull up the news?", "Do you want me to pull up the news?"),
        (
            "The match starts at 8. Should I check the latest team news?\n\nWeb sources:\n• https://example.com/a",
            "Should I check the latest team news?"
        ),
        ("I\u{2019}d say so. Want me to look it up to be sure?", "Want me to look it up to be sure?"),
    ])
    func offers(reply: String, offer: String) {
        let history = [ChatTurn(role: .user, text: "hm"), ChatTurn(role: .assistant, text: reply)]
        #expect(ToolNeedRouter.lookupOffer(in: history) == offer)
    }

    @Test("no lookup offer", arguments: [
        "Want me to write you a short story about a dragon?",
        "Shall I tell you a joke?",
        "I could look that up last time.",
        "Want me to check the forecast? Or I can just tell you a story.",
        "Here's what I found.\n\nWeb sources:\n• https://example.com/a",
        "Cork is lovely in October.",
    ])
    func noOffer(reply: String) {
        let history = [ChatTurn(role: .user, text: "hm"), ChatTurn(role: .assistant, text: reply)]
        #expect(ToolNeedRouter.lookupOffer(in: history) == nil)
    }

    @Test("only the previous assistant reply can carry the offer")
    func offerNeedsTheLastTurn() {
        #expect(ToolNeedRouter.lookupOffer(in: []) == nil)
        let userLast = [
            ChatTurn(role: .assistant, text: "Want me to search for flights to Lisbon?"),
            ChatTurn(role: .user, text: "hmm"),
        ]
        #expect(ToolNeedRouter.lookupOffer(in: userLast) == nil)
    }

    @Test("the picker's message: the offer on one line, no quotes, capped, then the reply")
    func pickMessage() {
        let message = ToolNeedRouter.offerPickMessage(
            offer: "Want me to search for \"jazz\"\nin Cork?", reply: "Yes please"
        )
        #expect(!message.contains("\""))
        #expect(message.contains("search for jazz in Cork?"))
        #expect(message.hasSuffix("Yes please"))
        #expect(message.split(separator: "\n").count == 2)

        let long = ToolNeedRouter.offerPickMessage(
            offer: "Want me to search for " + String(repeating: "dragons ", count: 80) + "?", reply: "yes"
        )
        #expect(long.count < 260)
        #expect(long.hasSuffix("yes"))
    }

    @Test("an offer's pick is kept only when it is about the offer")
    func keptPicks() {
        let offer = "Want me to search for events in Cork this weekend?"
        let kept = ToolPick(tool: "web_search", query: "events in Cork")
        #expect(ToolNeedRouter.keptOfferPick(kept, offer: offer) == kept)
        let none = ToolPick(tool: ToolPick.noTool, query: "")
        let dropped: [ToolPick] = [
            ToolPick(tool: "web_search", query: "current weather in New York"),
            ToolPick(tool: "web_search", query: ""),
            ToolPick(tool: "web_search", query: "search the latest"),
            ToolPick(tool: "datetime", query: ""),
            ToolPick(tool: ToolPick.action, query: "events in Cork"),
        ]
        for pick in dropped {
            #expect(ToolNeedRouter.keptOfferPick(pick, offer: offer) == none, "kept \(pick)")
        }
        #expect(ToolNeedRouter.keptOfferPick(none, offer: offer) == none)
        #expect(ToolNeedRouter.keptOfferPick(nil, offer: offer) == nil)

        let calendar = "Shall I check your calendar for tomorrow?"
        let peek = ToolPick(tool: "calendar_peek", query: "")
        #expect(ToolNeedRouter.keptOfferPick(peek, offer: calendar) == peek)
        #expect(ToolNeedRouter.keptOfferPick(ToolPick(tool: "battery_status", query: ""), offer: calendar) == none)

        // A chain keeps the links about the offer.
        let chain = ToolPick(
            tool: "web_search", query: "weather in New York",
            then: [ToolPick(tool: "web_search", query: "Cork events")]
        )
        #expect(ToolNeedRouter.keptOfferPick(chain, offer: offer) == ToolPick(tool: "web_search", query: "Cork events"))
    }
}
