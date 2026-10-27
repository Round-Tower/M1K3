//
//  ChatGPTExportParserTests.swift
//  M1K3ImportTests
//
//  #711: ChatGPT's `conversations.json` is an array of conversations whose messages sit in a
//  `mapping` TREE (every edit or regeneration forks it). The conversation the user saw is the
//  branch from `current_node` up through `parent` links; abandoned branches never become text.
//  Lenient by rule: unknown keys are ignored, a malformed node is skipped, and only a root that
//  is not a JSON array throws.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.75 (synthetic fixtures; owed a hand
//  check against a real export).
//  Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-27 (pre-push review fold) — the walk's guards are pinned (a parent cycle, a
//  self-parent, a dangling parent, a null current_node, no leaf at all), the id chain (conversation_id → id → a
//  content-derived id, stable across positions), the first-user-line title, first-wins duplicate ids, the skipped
//  custom-instructions node, and create_time that is a bool or a string. Confidence 0.8.

import Foundation
@testable import M1K3Import
import Testing

struct ChatGPTExportParserTests {
    @Test("only the branch ending at current_node is imported, root to leaf")
    func mainBranchOnly() throws {
        typealias Node = ChatGPTFixture.Node
        let conversation = ChatGPTFixture.conversation(
            id: "c1", title: "Trip to Kerry", createTime: 1_760_000_000,
            nodes: [
                Node(id: "root", parent: nil, role: nil),
                Node(id: "sys", parent: "root", role: "system", parts: [""], hidden: true),
                Node(id: "u1", parent: "sys", role: "user", parts: ["Plan a weekend in Kerry for me"]),
                Node(id: "a1", parent: "u1", role: "assistant", parts: ["Happy to. Where will you sleep?"]),
                Node(id: "u2a", parent: "a1", role: "user", parts: ["I prefer hostels"]),
                Node(id: "a2a", parent: "u2a", role: "assistant", parts: ["Hostels it is."]),
                Node(id: "u2b", parent: "a1", role: "user", parts: ["I prefer camping"]),
                Node(id: "a2b", parent: "u2b", role: "assistant", parts: ["Camping it is."]),
            ],
            current: "a2b"
        )

        let bundle = try ChatGPTExportParser.parse(data: ChatGPTFixture.data([conversation]))

        let parsed = try #require(bundle.conversations.first)
        #expect(bundle.provider == .chatgpt)
        #expect(parsed.id == "c1")
        #expect(parsed.title == "Trip to Kerry")
        #expect(parsed.createdAt == Date(timeIntervalSince1970: 1_760_000_000))
        #expect(parsed.messages.map(\.text) == [
            "Plan a weekend in Kerry for me", "Happy to. Where will you sleep?",
            "I prefer camping", "Camping it is.",
        ])
        #expect(parsed.messages.map(\.role) == [.user, .assistant, .user, .assistant])
    }

    @Test("system, tool, tool-call, hidden and empty nodes drop; multimodal keeps its strings")
    func rolesAndPartsFiltered() throws {
        typealias Node = ChatGPTFixture.Node
        let conversation = ChatGPTFixture.conversation(
            id: "c2", title: "Photo question", createTime: nil,
            nodes: [
                Node(id: "root", parent: nil, role: nil),
                Node(id: "sys", parent: "root", role: "system", parts: ["You are ChatGPT"]),
                Node(
                    id: "u1", parent: "sys", role: "user",
                    parts: [["content_type": "image_asset_pointer", "asset_pointer": "file-service://x"], "What bird is this?"],
                    contentType: "multimodal_text", createTime: 1_760_000_100
                ),
                Node(
                    id: "call", parent: "u1", role: "assistant", parts: ["search(\"bird\")"],
                    recipient: "browser"
                ),
                Node(id: "tool", parent: "call", role: "tool", parts: ["results…"]),
                Node(id: "code", parent: "tool", role: "assistant", parts: ["print(1)"], contentType: "code"),
                Node(id: "hidden", parent: "code", role: "assistant", parts: ["(hidden)"], hidden: true),
                Node(id: "empty", parent: "hidden", role: "assistant", parts: ["   "]),
                Node(id: "a1", parent: "empty", role: "assistant", parts: ["A robin."]),
            ],
            current: "a1"
        )

        let bundle = try ChatGPTExportParser.parse(data: ChatGPTFixture.data([conversation]))

        let parsed = try #require(bundle.conversations.first)
        #expect(parsed.messages.map(\.text) == ["What bird is this?", "A robin."])
        #expect(parsed.messages.first?.createdAt == Date(timeIntervalSince1970: 1_760_000_100))
        #expect(parsed.messages.last?.createdAt == nil)
        #expect(parsed.createdAt == nil)
    }

    @Test("a malformed node or conversation is skipped, not thrown")
    func malformedPiecesAreSkipped() throws {
        var broken = ChatGPTFixture.linear(
            id: "c3", title: "Bees", createTime: 1_760_000_000,
            messages: [("user", "I keep bees in Kinsale"), ("assistant", "Lovely.")]
        )
        var mapping = try #require(broken["mapping"] as? [String: Any])
        var node = try #require(mapping["c3-m1"] as? [String: Any])
        node["message"] = "not an object"
        mapping["c3-m1"] = node
        broken["mapping"] = mapping
        let roots: [Any] = [broken, "a string where a conversation should be", ["mapping": 42]]

        let bundle = try ChatGPTExportParser.parse(data: JSONSerialization.data(withJSONObject: roots))

        #expect(bundle.conversations.count == 1)
        #expect(bundle.conversations.first?.messages.map(\.text) == ["I keep bees in Kinsale"])
    }

    @Test("a root that is not an array throws; so does a file that is not JSON")
    func nonArrayRootThrows() throws {
        let object = try JSONSerialization.data(withJSONObject: ["conversations": [] as [Any]])
        #expect(throws: ImportParseError.unexpectedShape) { try ChatGPTExportParser.parse(data: object) }
        #expect(throws: ImportParseError.notJSON) { try ChatGPTExportParser.parse(data: Data("nope".utf8)) }
        #expect(try ChatGPTExportParser.parse(data: Data("[]".utf8)).conversations.isEmpty)
    }

    @Test("a missing current_node falls back to the newest leaf; no title falls back to the first user line")
    func fallbacks() throws {
        typealias Node = ChatGPTFixture.Node
        let conversation = ChatGPTFixture.conversation(
            id: "c4", title: nil,
            nodes: [
                Node(id: "root", parent: nil, role: nil),
                Node(id: "u1", parent: "root", role: "user", parts: ["Old question"], createTime: 10),
                Node(id: "a1", parent: "u1", role: "assistant", parts: ["Old answer"], createTime: 11),
                Node(id: "u2", parent: "root", role: "user", parts: ["Edited question"], createTime: 20),
                Node(id: "a2", parent: "u2", role: "assistant", parts: ["New answer"], createTime: 21),
            ],
            current: "not-in-the-mapping"
        )

        let parsed = try #require(
            try ChatGPTExportParser.parse(data: ChatGPTFixture.data([conversation])).conversations.first
        )

        #expect(parsed.messages.map(\.text) == ["Edited question", "New answer"])
        #expect(parsed.title == "Edited question")
    }

    @Test("a conversation with nothing but system text is dropped")
    func emptyConversationsDrop() throws {
        let onlySystem = ChatGPTFixture.linear(id: "c5", title: "Empty", createTime: 1, messages: [])
        #expect(try ChatGPTExportParser.parse(data: ChatGPTFixture.data([onlySystem])).conversations.isEmpty)
    }

    // MARK: - Review fold: the walk's guards

    typealias Node = ChatGPTFixture.Node

    @Test("a parent cycle or a self-parent ends the walk instead of hanging it", .timeLimit(.minutes(1)))
    func cyclesEndTheWalk() throws {
        let loop = ChatGPTFixture.conversation(
            id: "loop", title: "Loop",
            nodes: [
                Node(id: "a", parent: "b", role: "user", parts: ["I keep bees"]),
                Node(id: "b", parent: "a", role: "assistant", parts: ["Lovely."]),
            ],
            current: "a"
        )
        let selfParent = ChatGPTFixture.conversation(
            id: "self", title: "Self",
            nodes: [Node(id: "s", parent: "s", role: "user", parts: ["I play the fiddle"])],
            current: "s"
        )

        let bundle = try ChatGPTExportParser.parse(data: ChatGPTFixture.data([loop, selfParent]))

        #expect(bundle.conversations.map(\.id) == ["loop", "self"])
        #expect(bundle.conversations.first?.messages.map(\.text) == ["Lovely.", "I keep bees"])
        #expect(bundle.conversations.last?.messages.map(\.text) == ["I play the fiddle"])
    }

    @Test("a dangling parent keeps the messages up to the break; no leaf and no current_node drops it")
    func danglingParentAndNoLeaf() throws {
        let dangling = ChatGPTFixture.conversation(
            id: "dangling", title: "Dangling",
            nodes: [
                Node(id: "u1", parent: "gone", role: "user", parts: ["I row on the Lee"]),
                Node(id: "a1", parent: "u1", role: "assistant", parts: ["Nice."]),
            ],
            current: "a1"
        )
        // Every node names a child, so there is no leaf to fall back to.
        var noLeaf = ChatGPTFixture.conversation(
            id: "no-leaf", title: "No leaf",
            nodes: [
                Node(id: "x", parent: "y", role: "user", parts: ["Hello there friend"]),
                Node(id: "y", parent: "x", role: "assistant", parts: ["Hi."]),
            ],
            current: nil
        )
        noLeaf["current_node"] = nil

        let bundle = try ChatGPTExportParser.parse(data: ChatGPTFixture.data([dangling, noLeaf]))

        #expect(bundle.conversations.map(\.id) == ["dangling"])
        #expect(bundle.conversations.first?.messages.map(\.text) == ["I row on the Lee", "Nice."])
    }

    @Test("a null current_node falls back to the newest leaf, like a missing one")
    func nullCurrentNode() throws {
        let conversation = ChatGPTFixture.conversation(
            id: "c6", title: "Null",
            nodes: [
                Node(id: "root", parent: nil, role: nil),
                Node(id: "u1", parent: "root", role: "user", parts: ["Old question"], createTime: 10),
                Node(id: "u2", parent: "root", role: "user", parts: ["Edited question"], createTime: 20),
            ],
            current: nil
        )
        #expect(conversation["current_node"] is NSNull)

        let bundle = try ChatGPTExportParser.parse(data: ChatGPTFixture.data([conversation]))
        let parsed = try #require(bundle.conversations.first)

        #expect(parsed.messages.map(\.text) == ["Edited question"])
    }

    @Test("custom instructions (user_editable_context) never become a user turn")
    func customInstructionsAreSkipped() throws {
        let conversation = ChatGPTFixture.conversation(
            id: "c7", title: "Instructions",
            nodes: [
                Node(id: "root", parent: nil, role: nil),
                Node(id: "ctx", parent: "root", role: "user", parts: [], contentType: "user_editable_context"),
                Node(id: "u1", parent: "ctx", role: "user", parts: ["I keep bees"]),
            ],
            current: "u1"
        )
        var mapping = try #require(conversation["mapping"] as? [String: Any])
        var context = try #require(mapping["ctx"] as? [String: Any])
        var message = try #require(context["message"] as? [String: Any])
        message["content"] = [
            "content_type": "user_editable_context",
            "user_profile": "I am a beekeeper in Kinsale",
            "user_instructions": "Answer briefly",
        ]
        context["message"] = message
        mapping["ctx"] = context
        var edited = conversation
        edited["mapping"] = mapping

        let bundle = try ChatGPTExportParser.parse(data: ChatGPTFixture.data([edited]))
        let parsed = try #require(bundle.conversations.first)

        #expect(parsed.messages.map(\.text) == ["I keep bees"])
    }

    // MARK: - Review fold: ids

    @Test("the id is conversation_id, then id, then derived from the content — never the file position")
    func idFallbacks() throws {
        let linear = { (id: String, text: String) in
            ChatGPTFixture.linear(id: id, title: "T", createTime: 1, messages: [("user", text)])
        }
        var idOnly = linear("only-id", "I keep bees")
        idOnly["conversation_id"] = nil
        var anonymous = linear("x", "I play the fiddle")
        anonymous["conversation_id"] = nil
        anonymous["id"] = nil
        var other = linear("y", "I row on the Lee")
        other["conversation_id"] = nil
        other["id"] = nil

        let first = try ChatGPTExportParser.parse(data: ChatGPTFixture.data([idOnly, anonymous]))
        let moved = try ChatGPTExportParser.parse(data: ChatGPTFixture.data([other, idOnly, anonymous]))

        #expect(first.conversations.first?.id == "only-id")
        let derived = try #require(first.conversations.last?.id)
        #expect(derived.hasPrefix("derived-"))
        #expect(moved.conversations.last?.id == derived, "the same chat at another position keeps its id")
        #expect(moved.conversations.first?.id != derived, "a different chat at its old position gets another")
        #expect(moved.conversations.first?.id.hasPrefix("derived-") == true)
    }

    @Test("a repeated conversation id keeps the first conversation")
    func duplicateIDsKeepTheFirst() throws {
        let first = ChatGPTFixture.linear(id: "dup", title: "First", createTime: 1, messages: [("user", "I keep bees")])
        let second = ChatGPTFixture.linear(id: "dup", title: "Second", createTime: 2, messages: [("user", "I row")])

        let bundle = try ChatGPTExportParser.parse(data: ChatGPTFixture.data([first, second]))

        #expect(bundle.conversations.map(\.title) == ["First"])
    }

    @Test("a create_time that is a bool or a string is no date")
    func nonNumericCreateTime() throws {
        let said = [(role: "user", text: "I keep bees")]
        var asBool = ChatGPTFixture.linear(id: "b", title: "Bool", createTime: 1, messages: said)
        asBool["create_time"] = true
        var asString = ChatGPTFixture.linear(id: "s", title: "String", createTime: 1, messages: said)
        asString["create_time"] = "123"

        let bundle = try ChatGPTExportParser.parse(data: ChatGPTFixture.data([asBool, asString]))

        #expect(bundle.conversations.count == 2)
        #expect(bundle.conversations.allSatisfy { $0.createdAt == nil })
    }
}
