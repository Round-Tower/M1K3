//
//  AnswerFeedbackTests.swift
//  M1K3ChatTests
//
//  Store round-trips against the in-memory GRDB harness, plus the pure export.
//
//  Signed: Kev + claude-fable-5, 2026-08-19, Confidence 0.9, Prior: Unknown
//

import Foundation
@testable import M1K3Chat
import Testing

private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func feedback(
    message: UUID, conversation: UUID, verdict: FeedbackVerdict,
    comment: String? = nil, tools: [String] = [], brain: String = "lil"
) -> AnswerFeedback {
    AnswerFeedback(
        messageID: message, conversationID: conversation, verdict: verdict,
        comment: comment, question: "Irish coffee in Cork?",
        answer: "It was invented at Foynes.", toolsUsed: tools, brain: brain, createdAt: t0
    )
}

struct AnswerFeedbackStoreTests {
    @Test("a recorded verdict round-trips and shows up in the conversation's verdict map")
    func recordAndRead() throws {
        let store = try GRDBChatHistoryStore()
        let convo = UUID()
        let msg = UUID()
        try store.recordFeedback(feedback(message: msg, conversation: convo, verdict: .bad,
                                          comment: "should have searched the web", tools: []))
        let verdicts = try store.feedbackVerdicts(conversationID: convo)
        #expect(verdicts[msg] == .bad)

        let all = try store.allFeedback()
        #expect(all.count == 1)
        #expect(all[0].comment == "should have searched the web")
        #expect(all[0].toolsUsed.isEmpty) // the tell: no web_search fired
    }

    @Test("re-rating the same answer REPLACES, never duplicates (message_id is the key)")
    func rerateReplaces() throws {
        let store = try GRDBChatHistoryStore()
        let convo = UUID()
        let msg = UUID()
        try store.recordFeedback(feedback(message: msg, conversation: convo, verdict: .bad))
        try store.recordFeedback(feedback(message: msg, conversation: convo, verdict: .good,
                                          comment: "actually fine"))
        let all = try store.allFeedback()
        #expect(all.count == 1)
        #expect(all[0].verdict == .good)
        #expect(all[0].comment == "actually fine")
    }

    @Test("verdicts are scoped to their conversation")
    func scopedToConversation() throws {
        let store = try GRDBChatHistoryStore()
        let a = UUID(), b = UUID()
        let msgA = UUID(), msgB = UUID()
        try store.recordFeedback(feedback(message: msgA, conversation: a, verdict: .good))
        try store.recordFeedback(feedback(message: msgB, conversation: b, verdict: .bad))
        #expect(try store.feedbackVerdicts(conversationID: a) == [msgA: .good])
        #expect(try store.feedbackVerdicts(conversationID: b) == [msgB: .bad])
    }

    @Test("tools survive the JSON round-trip through the column")
    func toolsRoundTrip() throws {
        let store = try GRDBChatHistoryStore()
        let msg = UUID()
        try store.recordFeedback(feedback(message: msg, conversation: UUID(), verdict: .good,
                                          tools: ["web_search", "date_time"]))
        #expect(try store.allFeedback().first?.toolsUsed == ["web_search", "date_time"])
    }

    @Test("the brain STAMPED on an answer round-trips — the feedback row's provenance")
    func brainProvenanceRoundTrips() throws {
        let store = try GRDBChatHistoryStore()
        let msg = UUID()
        try store.recordFeedback(feedback(message: msg, conversation: UUID(), verdict: .bad, brain: "Big"))
        #expect(try store.allFeedback().first?.brain == "Big")
    }
}

struct ChatMessageBrainTests {
    @Test("brain persists through the ChatMessage codable round-trip; pre-trace decodes to nil")
    func brainCodable() throws {
        var message = ChatMessage(id: UUID(), role: .assistant, text: "hi", status: .complete)
        message.brain = "Lil"
        let data = try JSONEncoder().encode([message])
        let decoded = try JSONDecoder().decode([ChatMessage].self, from: data)
        #expect(decoded.first?.brain == "Lil")

        // A message with no brain omits the key (optionals encode-if-present),
        // so a pre-trace payload — which never wrote it — decodes to nil.
        let unstamped = ChatMessage(id: UUID(), role: .assistant, text: "old", status: .complete)
        let unstampedData = try JSONEncoder().encode([unstamped])
        #expect(!String(decoding: unstampedData, as: UTF8.self).contains("brain"))
        let old = try JSONDecoder().decode([ChatMessage].self, from: unstampedData)
        #expect(old.first?.brain == nil)
    }
}

struct AnswerFeedbackModelTests {
    @Test("a blank comment normalises to nil — \"\" and no-note are one state")
    func blankCommentIsNil() {
        let f = feedback(message: UUID(), conversation: UUID(), verdict: .good, comment: "   ")
        #expect(f.comment == nil)
    }

    @Test("export renders one JSONL line per row with the verdict, tools, and optional comment")
    func exportShape() {
        let rows = [
            feedback(message: UUID(), conversation: UUID(), verdict: .bad,
                     comment: "no web search", tools: []),
            feedback(message: UUID(), conversation: UUID(), verdict: .good, tools: ["web_search"]),
        ]
        let jsonl = AnswerFeedbackExport.jsonl(rows) { _ in "2026-08-19T00:00:00Z" }
        let lines = jsonl.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].contains("\"verdict\":\"bad\""))
        #expect(lines[0].contains("\"comment\":\"no web search\""))
        #expect(lines[1].contains("\"verdict\":\"good\""))
        // A thumbs-up with no comment omits the key rather than emitting null.
        #expect(!lines[1].contains("comment"))
        // Sources are never exported (corpus side-channel guard) — only answer.
        #expect(!jsonl.contains("sources"))
    }
}
