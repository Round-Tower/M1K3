//
//  ImportFixtures.swift
//  M1K3ImportTests
//
//  Synthetic export builders for #711. Every fixture is made up here, in the shapes the providers'
//  data exports use (ChatGPT `conversations.json`: a `mapping` tree walked from `current_node`;
//  Claude's `conversations.json`: `chat_messages` with `sender` and content blocks). No real
//  user's export is ever read or committed; the shapes are owed a hand check against a real file.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.75 (shapes written from knowledge of
//  the formats, not checked against a live export in this tree).
//  Prior: none (new file).

import Foundation

enum ChatGPTFixture {
    struct Node {
        var id: String
        var parent: String?
        var role: String?
        var parts: [Any] = []
        var contentType = "text"
        var createTime: Double? = nil
        var hidden = false
        var recipient: String? = "all"
    }

    /// A mapping tree; children are derived from the parents so a fork is two nodes naming one parent.
    static func conversation(
        id: String, title: String?, createTime: Double? = nil, nodes: [Node], current: String?
    ) -> [String: Any] {
        var mapping: [String: Any] = [:]
        for node in nodes {
            let children = nodes.filter { $0.parent == node.id }.map(\.id)
            var entry: [String: Any] = [
                "id": node.id, "parent": node.parent as Any? ?? NSNull(), "children": children,
            ]
            if let role = node.role {
                var message: [String: Any] = [
                    "id": node.id,
                    "author": ["role": role, "name": NSNull(), "metadata": [:] as [String: Any]],
                    "content": ["content_type": node.contentType, "parts": node.parts],
                    "create_time": node.createTime as Any? ?? NSNull(),
                    "status": "finished_successfully",
                    "weight": 1.0,
                    "metadata": node.hidden ? ["is_visually_hidden_from_conversation": true] : [:],
                    "an_unknown_key_from_a_newer_export": ["ignored": true],
                ]
                if let recipient = node.recipient {
                    message["recipient"] = recipient
                }
                entry["message"] = message
            } else {
                entry["message"] = NSNull()
            }
            mapping[node.id] = entry
        }
        var object: [String: Any] = [
            "title": title as Any? ?? NSNull(),
            "create_time": createTime as Any? ?? NSNull(),
            "update_time": NSNull(),
            "mapping": mapping,
            "conversation_id": id,
            "id": id,
            "moderation_results": [] as [Any],
        ]
        object["current_node"] = current as Any? ?? NSNull()
        return object
    }

    /// A straight-line conversation: a null root, a hidden system prompt, then the messages.
    static func linear(
        id: String, title: String, createTime: Double, messages: [(role: String, text: String)]
    ) -> [String: Any] {
        var nodes = [
            Node(id: "\(id)-root", parent: nil, role: nil),
            Node(id: "\(id)-sys", parent: "\(id)-root", role: "system", parts: [""], hidden: true),
        ]
        var parent = "\(id)-sys"
        for (offset, message) in messages.enumerated() {
            let nodeID = "\(id)-m\(offset)"
            nodes.append(Node(
                id: nodeID, parent: parent, role: message.role, parts: [message.text],
                createTime: createTime + Double(offset)
            ))
            parent = nodeID
        }
        return conversation(id: id, title: title, createTime: createTime, nodes: nodes, current: parent)
    }

    static func data(_ conversations: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: conversations)
    }
}

enum ClaudeFixture {
    static func message(
        sender: String, text: String, blocks: [[String: Any]]? = nil,
        createdAt: String = "2026-03-01T09:30:00.123456Z"
    ) -> [String: Any] {
        var object: [String: Any] = [
            "uuid": UUID().uuidString.lowercased(),
            "sender": sender,
            "text": text,
            "created_at": createdAt,
            "updated_at": createdAt,
            "attachments": [] as [Any],
            "files": [] as [Any],
        ]
        if let blocks {
            object["content"] = blocks
        }
        return object
    }

    static func conversation(
        uuid: String, name: String, createdAt: String = "2026-03-01T09:29:58.000001Z",
        messages: [[String: Any]]
    ) -> [String: Any] {
        [
            "uuid": uuid,
            "name": name,
            "created_at": createdAt,
            "updated_at": createdAt,
            "account": ["uuid": "00000000-0000-0000-0000-000000000000"],
            "chat_messages": messages,
        ]
    }

    static func data(_ conversations: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: conversations)
    }
}

/// A UTC date from components, for pinning `import/<provider>/<yyyy-MM-dd>` days.
func utcDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(
        year: year, month: month, day: day, hour: hour, minute: minute
    ))!
}
