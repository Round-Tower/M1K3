//
//  ImportedConversationTests.swift
//  M1K3ImportTests
//
//  #711: the common model every parser produces, and its two renderings — the turns the memory
//  distiller reads, and the single page the knowledge corpus files and cites.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85.
//  Prior: none (new file).

import Foundation
import M1K3Chat
@testable import M1K3Import
import M1K3Knowledge
import Testing

struct ImportedConversationTests {
    private let conversation = ImportedConversation(
        id: "c1", title: "Bees", createdAt: Date(timeIntervalSince1970: 100),
        messages: [
            ImportedMessage(role: .user, text: "I keep bees in Kinsale"),
            ImportedMessage(role: .assistant, text: "Lovely.\nHow many hives?"),
            ImportedMessage(role: .user, text: "Three"),
        ]
    )

    @Test("chatTurns keep the order and the roles")
    func chatTurns() {
        #expect(conversation.chatTurns == [
            ChatTurn(role: .user, text: "I keep bees in Kinsale"),
            ChatTurn(role: .assistant, text: "Lovely.\nHow many hives?"),
            ChatTurn(role: .user, text: "Three"),
        ])
    }

    @Test("pages are ONE page with a role label per message, so no label is eaten as a running header")
    func pages() {
        #expect(conversation.pages == [DocumentPage(
            pageNumber: 1,
            text: "User: I keep bees in Kinsale\nAssistant: Lovely.\nHow many hives?\nUser: Three"
        )])
        let chunks = DocumentChunker.chunk(pages: conversation.pages)
        #expect(chunks.count == 1)
        #expect(chunks.first?.content.contains("User: Three") == true)
    }

    @Test("chronological order: oldest first, undated first, ties keep export order")
    func chronological() {
        func make(_ id: String, _ seconds: Double?) -> ImportedConversation {
            ImportedConversation(
                id: id, title: id, createdAt: seconds.map(Date.init(timeIntervalSince1970:)),
                messages: [ImportedMessage(role: .user, text: "x")]
            )
        }
        let bundle = ImportBundle(
            provider: .chatgpt,
            conversations: [make("new", 30), make("undated", nil), make("old", 10), make("tie-a", 20), make("tie-b", 20)]
        )
        #expect(bundle.chronologicalConversations.map(\.id) == ["undated", "old", "tie-a", "tie-b", "new"])
    }
}
