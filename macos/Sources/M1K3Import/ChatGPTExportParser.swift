//
//  ChatGPTExportParser.swift
//  M1K3Import
//
//  ChatGPT's data export `conversations.json` (#711): an array of conversations, each holding its
//  messages as a `mapping` TREE keyed by node id (every edit or regeneration forks it). The
//  conversation the user last saw is the branch from `current_node` up through `parent` links,
//  reversed. Kept: user and assistant messages addressed to everyone, `text` or the string parts
//  of `multimodal_text`. Dropped: system and tool nodes, tool calls (`recipient` other than
//  `all`), code / browsing / reasoning content types, hidden and empty messages.
//
//  Lenient by rule: unknown keys are ignored, a malformed node or conversation is skipped, and
//  only a root that is not a JSON array throws. The shape is written from knowledge of the
//  format and synthetic fixtures; a hand check against a real export is owed (PR follow-ups).
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.75.
//  Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-27 (pre-push review fold) — no positional `index-N` id: a conversation with
//  neither `conversation_id` nor `id` gets a content-derived one; an untitled one takes its first user line; a
//  repeated id keeps its first conversation. Cycle, dangling-parent and no-leaf walks are now pinned. Confidence 0.8.

import Foundation

public enum ChatGPTExportParser {
    public static func parse(data: Data) throws -> ImportBundle {
        try parse(root: ImportJSON.root(of: data))
    }

    static func parse(root: Any) throws -> ImportBundle {
        guard let array = root as? [Any] else { throw ImportParseError.unexpectedShape }
        let conversations = array.compactMap { ($0 as? [String: Any]).flatMap(conversation(from:)) }
        return ImportBundle(provider: .chatgpt, conversations: ImportJSON.uniqueByID(conversations))
    }

    private static func conversation(from object: [String: Any]) -> ImportedConversation? {
        guard let mapping = object["mapping"] as? [String: Any] else { return nil }
        let nodes = mapping.compactMapValues { $0 as? [String: Any] }
        let messages = mainBranch(of: nodes, from: object["current_node"] as? String).compactMap(message(from:))
        guard !messages.isEmpty else { return nil }
        let title = ImportJSON.nonEmpty(object["title"] as? String)
        let createdAt = ImportDates.epoch(object["create_time"])
        let id = ImportJSON.nonEmpty(object["conversation_id"] as? String)
            ?? ImportJSON.nonEmpty(object["id"] as? String)
            ?? ImportJSON.derivedID(title: title, createdAt: createdAt, messages: messages)
        return ImportedConversation(
            id: id,
            title: title ?? ImportJSON.titleExcerpt(of: messages),
            createdAt: createdAt,
            messages: messages
        )
    }

    /// Root → leaf along `parent` links from `current`; the newest leaf when `current` is
    /// missing or names no node. A cycle ends the walk instead of hanging it.
    private static func mainBranch(of nodes: [String: [String: Any]], from current: String?) -> [[String: Any]] {
        var cursor = current.flatMap { nodes[$0] == nil ? nil : $0 } ?? newestLeaf(of: nodes)
        var path: [[String: Any]] = []
        var seen: Set<String> = []
        while let id = cursor, let node = nodes[id], seen.insert(id).inserted {
            path.append(node)
            cursor = node["parent"] as? String
        }
        return path.reversed()
    }

    private static func newestLeaf(of nodes: [String: [String: Any]]) -> String? {
        let leaves = nodes.filter { ($0.value["children"] as? [Any])?.isEmpty ?? true }
        return leaves.max { lhs, rhs in
            let left = createTime(of: lhs.value), right = createTime(of: rhs.value)
            return left == right ? lhs.key < rhs.key : left < right
        }?.key
    }

    private static func createTime(of node: [String: Any]) -> Double {
        ImportDates.epoch((node["message"] as? [String: Any])?["create_time"])?.timeIntervalSince1970 ?? 0
    }

    private static func message(from node: [String: Any]) -> ImportedMessage? {
        guard let message = node["message"] as? [String: Any],
              let author = message["author"] as? [String: Any],
              let role = role(author["role"] as? String)
        else { return nil }
        if (message["metadata"] as? [String: Any])?["is_visually_hidden_from_conversation"] as? Bool == true {
            return nil
        }
        if let recipient = message["recipient"] as? String, recipient != "all" { return nil }
        guard let content = message["content"] as? [String: Any],
              let type = content["content_type"] as? String, type == "text" || type == "multimodal_text",
              let parts = content["parts"] as? [Any],
              let text = ImportJSON.nonEmpty(parts.compactMap { $0 as? String }.joined(separator: "\n"))
        else { return nil }
        return ImportedMessage(role: role, text: text, createdAt: ImportDates.epoch(message["create_time"]))
    }

    private static func role(_ raw: String?) -> ImportedRole? {
        switch raw {
        case "user": .user
        case "assistant": .assistant
        default: nil
        }
    }
}
