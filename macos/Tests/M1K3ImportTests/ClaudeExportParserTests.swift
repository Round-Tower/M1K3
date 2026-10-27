//
//  ClaudeExportParserTests.swift
//  M1K3ImportTests
//
//  #711: the Claude data export's `conversations.json` (inside the archive; unpacking the .zip is
//  the import UI's job) is an array of conversations with `chat_messages`, each a `sender`
//  (human / assistant), a top-level `text`, and newer `content` blocks. Text blocks win when
//  present; tool blocks never become text.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.75 (synthetic fixtures; owed a hand
//  check against a real export).
//  Prior: none (new file).

import Foundation
@testable import M1K3Import
import Testing

struct ClaudeExportParserTests {
    @Test("senders map to roles, text blocks join, dates with microseconds parse")
    func sendersDatesAndContentBlocks() throws {
        let conversation = ClaudeFixture.conversation(
            uuid: "9f1c", name: "Fiddle practice",
            messages: [
                ClaudeFixture.message(
                    sender: "human", text: "stale top-level text",
                    blocks: [
                        ["type": "text", "text": "I play the fiddle"],
                        ["type": "tool_use", "name": "search", "input": [:] as [String: Any]],
                        ["type": "text", "text": "every Sunday in Cobh"],
                    ],
                    createdAt: "2026-03-01T09:30:00.123456Z"
                ),
                ClaudeFixture.message(sender: "assistant", text: "That sounds lovely.", blocks: []),
                ClaudeFixture.message(sender: "system", text: "ignored"),
            ]
        )

        let bundle = try ClaudeExportParser.parse(data: ClaudeFixture.data([conversation]))

        let parsed = try #require(bundle.conversations.first)
        #expect(bundle.provider == .claude)
        #expect(parsed.id == "9f1c")
        #expect(parsed.title == "Fiddle practice")
        #expect(parsed.messages.map(\.role) == [.user, .assistant])
        #expect(parsed.messages.map(\.text) == ["I play the fiddle\n\nevery Sunday in Cobh", "That sounds lovely."])
        let stamp = try #require(parsed.messages.first?.createdAt)
        #expect(abs(stamp.timeIntervalSince1970 - 1_772_357_400.123456) < 0.001)
        #expect(parsed.createdAt != nil)
    }

    @Test("an empty conversation drops; an empty name falls back to the uuid")
    func fallbacksAndDrops() throws {
        let empty = ClaudeFixture.conversation(uuid: "e1", name: "Nothing", messages: [])
        let unnamed = ClaudeFixture.conversation(
            uuid: "u1", name: "", createdAt: "not a date",
            messages: [ClaudeFixture.message(sender: "human", text: "I keep bees")]
        )

        let bundle = try ClaudeExportParser.parse(data: ClaudeFixture.data([empty, unnamed]))

        #expect(bundle.conversations.map(\.id) == ["u1"])
        #expect(bundle.conversations.first?.title == "u1")
        #expect(bundle.conversations.first?.createdAt == nil)
    }

    @Test("a root that is not an array throws")
    func nonArrayRootThrows() throws {
        let object = try JSONSerialization.data(withJSONObject: ["chat_messages": [] as [Any]])
        #expect(throws: ImportParseError.unexpectedShape) { try ClaudeExportParser.parse(data: object) }
    }
}
