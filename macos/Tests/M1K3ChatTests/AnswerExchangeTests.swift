//
//  AnswerExchangeTests.swift
//  M1K3ChatTests
//
//  `ChatSession.exchange(for:)` — the one-exchange value the "Send this exchange" sheet (#708)
//  is built from. The pin that matters: it carries the paired user turn and the answer's text,
//  and NOTHING else in the transcript — no other turn, no source chunk, no reasoning, no tool
//  names. `recordFeedback` pairs through the same call, so there is one pairing rule.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-26, Confidence 0.85 (in-memory GRDB store, the
//  AnswerFeedbackTests harness). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-26 (code-review fold) — a file turn leaves its attached text and
//  name behind (the stored turn holds every file's text); an answer with no user turn before it, and a
//  second answer behind one question, are pinned; the persistence poll is a 30 s valve. Confidence 0.85.
//

import Foundation
@testable import M1K3Chat
import M1K3Inference
import M1K3Knowledge
import Testing

/// A responder the tests never reach: every session here is seeded, never sent to.
private struct SilentResponder: RAGResponding {
    func answerStreaming(_: String) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        (sources: [], stream: AsyncStream { $0.finish() })
    }
}

private let chunkText = "Foynes flying-boat terminal, 1943: Joe Sheridan's warming coffee."
private let reasoningText = "The user asks about origins; recall the Foynes story."

/// Three exchanges. The SECOND answer carries everything a payload must leave behind:
/// a source chunk, a reasoning chain, a tool name and a brain stamp.
private struct Seed {
    let conversationID = UUID()
    let user1 = ChatMessage(role: .user, text: "Any plans for the weekend?", status: .complete)
    let answer1 = ChatMessage(role: .assistant, text: "Whatever you like — I'm here either way.", status: .complete)
    let user2 = ChatMessage(role: .user, text: "Where was Irish coffee invented?", status: .complete)
    let answer2: ChatMessage
    let user3 = ChatMessage(role: .user, text: "And who invented it?", status: .complete)
    let answer3 = ChatMessage(role: .assistant, text: "Joe Sheridan, the chef at Foynes.", status: .complete)

    init() {
        let hit = ChunkHit(
            chunkID: UUID(), itemID: UUID(), itemTitle: "Foynes notes", kind: .document,
            heading: "Origins", content: chunkText
        )
        var answer = ChatMessage(
            role: .assistant, text: "Foynes, County Limerick, in 1943.",
            sources: [hit], reasoning: reasoningText, status: .complete
        )
        answer.toolsUsed = ["web_search"]
        answer.brain = "Big"
        answer2 = answer
    }

    var messages: [ChatMessage] {
        [user1, answer1, user2, answer2, user3, answer3]
    }

    /// Other turns' words, the source chunk, the reasoning and the tool name: none may appear
    /// anywhere in the payload.
    var mustBeAbsent: [String] {
        [user1.text, answer1.text, user3.text, answer3.text, chunkText, reasoningText, "web_search"]
    }
}

@MainActor
struct AnswerExchangeTests {
    private static func seededSession() throws -> (ChatSession, GRDBChatHistoryStore, Seed) {
        let seed = Seed()
        let (session, store) = try session(resuming: seed.messages, id: seed.conversationID)
        return (session, store, seed)
    }

    private static func session(
        resuming messages: [ChatMessage], id: UUID = UUID()
    ) throws -> (ChatSession, GRDBChatHistoryStore) {
        let store = try GRDBChatHistoryStore()
        try store.save(id: id, messages: messages, updatedAt: Date())
        let session = ChatSession(responder: SilentResponder(), history: store)
        #expect(session.messages.count == messages.count, "the seeded conversation resumed")
        return (session, store)
    }

    /// Every String the value holds, found by reflection so a new field is covered too.
    private static func strings(of exchange: AnswerExchange) -> [String] {
        Mirror(reflecting: exchange).children.compactMap { child -> String? in
            if let s = child.value as? String { return s }
            if let s = child.value as? String? { return s }
            return nil
        }
    }

    @Test("the value is exactly the paired turn: messageID, conversationID, question, answer, brain")
    func fieldSetIsThePairedTurn() throws {
        let (session, _, seed) = try Self.seededSession()
        let exchange = try #require(session.exchange(for: seed.answer2.id))
        let labels = Mirror(reflecting: exchange).children.compactMap(\.label)
        #expect(labels == ["messageID", "conversationID", "question", "answer", "brain"])
    }

    @Test("an exchange carries only the paired turn — no other turn, source chunk, reasoning or tool name")
    func exchangeCarriesOnlyThePairedTurn() throws {
        let (session, _, seed) = try Self.seededSession()
        let exchange = try #require(session.exchange(for: seed.answer2.id))
        #expect(exchange.messageID == seed.answer2.id)
        #expect(exchange.conversationID == seed.conversationID)
        #expect(exchange.question == seed.user2.text)
        #expect(exchange.answer == seed.answer2.text)
        let carried = Self.strings(of: exchange)
        for forbidden in seed.mustBeAbsent {
            #expect(!carried.contains { $0.contains(forbidden) }, "the payload carries \(forbidden)")
        }
    }

    @Test("the brain stamped on the answer wins; an unstamped (pre-trace) answer reports nil — the shell supplies the fallback")
    func brainStampWinsAndNilWhenUnstamped() throws {
        let (session, _, seed) = try Self.seededSession()
        #expect(session.exchange(for: seed.answer2.id)?.brain == "Big")
        #expect(session.exchange(for: seed.answer1.id)?.brain == nil)
    }

    @Test("a user message or an unknown id has no exchange — the same guard recordFeedback has")
    func userAndUnknownIdsReturnNil() throws {
        let (session, _, seed) = try Self.seededSession()
        #expect(session.exchange(for: seed.user2.id) == nil)
        #expect(session.exchange(for: UUID()) == nil)
    }

    @Test("recordFeedback pairs through the same call: the persisted row matches the exchange, tools and stamp intact")
    func recordFeedbackPairsIdentically() async throws {
        let (session, store, seed) = try Self.seededSession()
        let exchange = try #require(session.exchange(for: seed.answer2.id))
        session.recordFeedback(messageID: seed.answer2.id, verdict: .bad, comment: "stale", brain: "Lil")
        #expect(session.feedbackVerdicts[seed.answer2.id] == .bad)

        // The row persists off the main actor (a .utility detached GRDB write). The ceiling is a
        // 30 s safety valve, not a timing claim: the passing path exits on the first row, and the
        // valve opening means the write never landed (the ChatSessionPrivateCloudTests idiom).
        var rows = try store.allFeedback()
        for _ in 0 ..< 3000 where rows.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
            rows = try store.allFeedback()
        }
        let row = try #require(rows.first)
        #expect(row.question == exchange.question)
        #expect(row.answer == exchange.answer)
        #expect(row.conversationID == exchange.conversationID)
        #expect(row.brain == "Big", "the stamp wins over the caller's fallback")
        #expect(row.toolsUsed == ["web_search"], "the feedback row keeps the tell; the exchange does not carry it")
    }

    @Test("a file turn sends the typed words only: the attached file's text and name stay on this Mac")
    func fileTurnLeavesTheFileBehind() throws {
        let fileText = "Clause 4: the house goes to Áine. Account 9921-44."
        let file = FileAttachment(filename: "settlement-draft.pdf", extractedText: fileText)
        // The turn exactly as ContentView.send builds it and ChatSession.send stores it.
        let stored = (file.contextBlock + "\n\n" + "What does clause 4 mean?")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let user = ChatMessage(role: .user, text: stored, status: .complete)
        let answer = ChatMessage(role: .assistant, text: "It assigns the house.", status: .complete)
        let (session, _) = try Self.session(resuming: [user, answer])
        #expect(session.messages.first?.text.contains(fileText) == true, "the transcript keeps the whole turn")

        let exchange = try #require(session.exchange(for: answer.id))
        #expect(exchange.question == "[1 attached file — not included]\n\nWhat does clause 4 mean?")
        for leaked in [fileText, "settlement-draft", "FILE:"] {
            #expect(!Self.strings(of: exchange).contains { $0.contains(leaked) }, "the payload carries \(leaked)")
        }
    }

    @Test("pairing is positional: an answer with no user turn before it gets none; a second answer shares the question")
    func answersWithoutTheirOwnQuestion() throws {
        // A background answer, a script's output or a PCC notice can land with no user turn of its own.
        let orphan = ChatMessage(role: .assistant, text: "Your script printed 42.", status: .complete)
        let user = ChatMessage(role: .user, text: "Summarise my week", status: .complete)
        let answerA = ChatMessage(role: .assistant, text: "A busy one.", status: .complete)
        let answerB = ChatMessage(role: .assistant, text: "The background answer.", status: .complete)
        let (session, _) = try Self.session(resuming: [orphan, user, answerA, answerB])
        #expect(session.exchange(for: orphan.id)?.question == "")
        #expect(session.exchange(for: answerA.id)?.question == user.text)
        #expect(session.exchange(for: answerB.id)?.question == user.text)
        #expect(session.exchange(for: answerB.id)?.answer == answerB.text)
    }
}
