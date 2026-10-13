//
//  PhoneAnswerActionsTests.swift
//  M1K3ChatTests
//
//  Kev, 2026-10-13, testing iOS heavily: the phone's answers need the Mac's row
//  (speak, copy, share, thumbs up, thumbs down with a note) so chat turns can be
//  rated and evaluated. Ratings land in the same store as the Mac's, and the
//  phone can export them as JSONL (the eval-fixture shape) from Settings.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-13, Confidence 0.85 (the export is
//  pure over the store; the row is a view, pinned by source scan and
//  verify-by-launch on the phone). Prior: none (new file).
//

import Foundation
@testable import M1K3Chat
import M1K3Knowledge
import Testing

private struct SilentResponder: RAGResponding {
    func answerStreaming(_: String) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        ([], AsyncStream { $0.finish() })
    }
}

@MainActor
struct PhoneAnswerActionsTests {
    private func rating(_ verdict: FeedbackVerdict, comment: String? = nil, at seconds: Double) -> AnswerFeedback {
        AnswerFeedback(
            messageID: UUID(), conversationID: UUID(), verdict: verdict, comment: comment,
            question: "What's the weather in Cork?", answer: "I can't check that offline.",
            toolsUsed: [], brain: "Lil", createdAt: Date(timeIntervalSince1970: seconds)
        )
    }

    @Test("the session exports every rating in the store as JSONL, one line per answer")
    func exportsTheStore() throws {
        let store = try GRDBChatHistoryStore()
        try store.recordFeedback(rating(.bad, comment: "should have searched the web", at: 1000))
        try store.recordFeedback(rating(.good, at: 2000))
        let session = ChatSession(responder: SilentResponder(), history: store)

        #expect(session.ratedAnswerCount() == 2)
        let lines = session.answerRatingsJSONL().split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.contains { $0.contains("should have searched the web") })
        #expect(try session.answerRatingsJSONL() == AnswerFeedbackExport.jsonl(store.allFeedback()) {
            $0.formatted(.iso8601)
        })
    }

    @Test("no store or no ratings: nothing to export, and the count says so")
    func emptyExport() throws {
        let bare = ChatSession(responder: SilentResponder(), history: nil)
        #expect(bare.ratedAnswerCount() == 0)
        #expect(bare.answerRatingsJSONL().isEmpty)
        let session = try ChatSession(responder: SilentResponder(), history: GRDBChatHistoryStore())
        #expect(session.answerRatingsJSONL().isEmpty)
    }

    @Test("the phone's answers carry the Mac's row, wired to the shared session")
    func phoneRowIsWired() throws {
        let bubble = try Self.source("M1K3iOSApp/MessageBubble.swift")
        for symbol in ["speaker.wave.2", "doc.on.doc", "square.and.arrow.up", "hand.thumbsup", "hand.thumbsdown"] {
            #expect(bubble.contains(symbol), "MessageBubble is missing \(symbol)")
        }
        #expect(bubble.contains("UIPasteboard.general.string = message.text"), "copy puts the answer's source on the pasteboard")
        #expect(bubble.contains("onFeedback(.bad, commentDraft)"), "thumbs-down commits with its note, on Done")

        let screen = try Self.source("M1K3iOSApp/ChatScreen.swift")
        #expect(screen.contains("core.chat.recordFeedback("), "ratings go to the shared store")
        #expect(screen.contains("core.reviewLedger.recordDelight()"), "a liked answer counts toward the rating ask, as on the Mac")
        #expect(screen.contains("core.readAloud("), "the speaker button reads the answer aloud")

        let settings = try Self.source("M1K3iOSApp/SettingsScreen.swift")
        #expect(settings.contains("answerRatingsJSONL()"), "Settings exports the ratings")
    }

    private static func source(_ relative: String) throws -> String {
        let macos = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: macos.appendingPathComponent(relative), encoding: .utf8)
    }
}
