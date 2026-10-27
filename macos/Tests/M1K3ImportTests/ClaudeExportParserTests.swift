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
//  Review: Kev + claude-opus-5.5, 2026-10-27 (pre-push review fold) — lenient by rule, now pinned like the ChatGPT
//  parser's (garbage elements, missing chat_messages, senders, empty and tool-only bodies), the content-derived id for
//  a missing uuid, the first-user-line title, the exact conversation instant and an explicit-offset date.
//  Confidence 0.8.

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
        let started = try #require(parsed.createdAt)
        #expect(abs(started.timeIntervalSince1970 - 1_772_357_398.000001) < 0.001)
    }

    @Test("an empty conversation drops; an empty name falls back to the first user line")
    func fallbacksAndDrops() throws {
        let empty = ClaudeFixture.conversation(uuid: "e1", name: "Nothing", messages: [])
        let unnamed = ClaudeFixture.conversation(
            uuid: "u1", name: "", createdAt: "not a date",
            messages: [ClaudeFixture.message(sender: "human", text: "I keep bees")]
        )

        let bundle = try ClaudeExportParser.parse(data: ClaudeFixture.data([empty, unnamed]))

        #expect(bundle.conversations.map(\.id) == ["u1"])
        #expect(bundle.conversations.first?.title == "I keep bees")
        #expect(bundle.conversations.first?.createdAt == nil)
    }

    @Test("a root that is not an array throws")
    func nonArrayRootThrows() throws {
        let object = try JSONSerialization.data(withJSONObject: ["chat_messages": [] as [Any]])
        #expect(throws: ImportParseError.unexpectedShape) { try ClaudeExportParser.parse(data: object) }
        #expect(throws: ImportParseError.notJSON) { try ClaudeExportParser.parse(data: Data("nope".utf8)) }
    }

    // MARK: - Review fold

    @Test("a malformed element, conversation or message is skipped, not thrown")
    func malformedPiecesAreSkipped() throws {
        let good = ClaudeFixture.conversation(
            uuid: "good", name: "Bees",
            messages: [
                ClaudeFixture.message(sender: "human", text: "I keep bees in Kinsale"),
                ["sender": NSNull(), "text": "a null sender"],
                ["text": "no sender at all"],
                ClaudeFixture.message(sender: "assistant", text: "   "),
                ClaudeFixture.message(sender: "user", text: "And a hive in Cobh"),
            ]
        )
        var notAList = ClaudeFixture.conversation(uuid: "bad", name: "Bad", messages: [])
        notAList["chat_messages"] = 42
        var missing = ClaudeFixture.conversation(uuid: "gone", name: "Gone", messages: [])
        missing["chat_messages"] = nil
        let messagesNotObjects = ClaudeFixture.conversation(uuid: "strings", name: "Strings", messages: [])
            .merging(["chat_messages": ["a string", 7]]) { $1 }
        let roots: [Any] = [good, "a string where a conversation should be", 7, notAList, missing, messagesNotObjects]

        let bundle = try ClaudeExportParser.parse(data: JSONSerialization.data(withJSONObject: roots))

        #expect(bundle.conversations.map(\.id) == ["good"])
        #expect(bundle.conversations.first?.messages.map(\.text) == ["I keep bees in Kinsale", "And a hive in Cobh"])
        #expect(bundle.conversations.first?.messages.map(\.role) == [.user, .user])
    }

    @Test("tool-only content falls back to the top-level text, or drops when that is empty too")
    func toolOnlyContent() throws {
        let toolOnly: [[String: Any]] = [["type": "tool_use", "name": "search", "input": [:] as [String: Any]]]
        let whitespace: [[String: Any]] = [["type": "text", "text": "   "]]
        let conversation = ClaudeFixture.conversation(
            uuid: "t1", name: "Tools",
            messages: [
                ClaudeFixture.message(sender: "human", text: "I keep bees", blocks: toolOnly),
                ClaudeFixture.message(sender: "assistant", text: "", blocks: toolOnly),
                ClaudeFixture.message(sender: "assistant", text: "Lovely.", blocks: whitespace),
            ]
        )

        let bundle = try ClaudeExportParser.parse(data: ClaudeFixture.data([conversation]))
        let parsed = try #require(bundle.conversations.first)

        #expect(parsed.messages.map(\.text) == ["I keep bees", "Lovely."])
    }

    @Test("a missing uuid gets an id derived from the content, the same wherever it sits in the file")
    func missingUUID() throws {
        var anonymous = ClaudeFixture.conversation(
            uuid: "x", name: "Fiddle", createdAt: "2026-03-01T09:29:58Z",
            messages: [ClaudeFixture.message(sender: "human", text: "I play the fiddle")]
        )
        anonymous["uuid"] = nil
        let named = ClaudeFixture.conversation(
            uuid: "n1", name: "Bees", messages: [ClaudeFixture.message(sender: "human", text: "I keep bees")]
        )

        let alone = try ClaudeExportParser.parse(data: ClaudeFixture.data([anonymous]))
        let second = try ClaudeExportParser.parse(data: ClaudeFixture.data([named, anonymous]))

        let id = try #require(alone.conversations.first?.id)
        #expect(id.hasPrefix("derived-"))
        #expect(second.conversations.last?.id == id)
    }

    @Test("created_at with an explicit offset parses to the same instant as Z")
    func explicitOffsetDates() throws {
        let conversation = ClaudeFixture.conversation(
            uuid: "o1", name: "Offset", createdAt: "2026-03-01T10:30:00+01:00",
            messages: [
                ClaudeFixture.message(sender: "human", text: "I keep bees", createdAt: "2026-03-01T09:30:00+00:00"),
            ]
        )

        let bundle = try ClaudeExportParser.parse(data: ClaudeFixture.data([conversation]))
        let parsed = try #require(bundle.conversations.first)

        #expect(parsed.createdAt == Date(timeIntervalSince1970: 1_772_357_400))
        #expect(parsed.messages.first?.createdAt == Date(timeIntervalSince1970: 1_772_357_400))
    }
}
