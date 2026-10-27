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

    @Test("a missing current_node falls back to the newest leaf; no title falls back to the id")
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
        #expect(parsed.title == "c4")
    }

    @Test("a conversation with nothing but system text is dropped")
    func emptyConversationsDrop() throws {
        let onlySystem = ChatGPTFixture.linear(id: "c5", title: "Empty", createTime: 1, messages: [])
        #expect(try ChatGPTExportParser.parse(data: ChatGPTFixture.data([onlySystem])).conversations.isEmpty)
    }
}
