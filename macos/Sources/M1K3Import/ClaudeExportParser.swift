//
//  ClaudeExportParser.swift
//  M1K3Import
//
//  The Claude data export's `conversations.json` (#711): an array of conversations with `uuid`,
//  `name`, `created_at` and `chat_messages`, each a `sender` (human / assistant), a top-level
//  `text` and, in newer exports, `content` blocks. Text blocks win when present (tool blocks
//  never become text); the top-level text is the fallback. Takes the extracted JSON: the export
//  arrives as a .zip, and unpacking it is the import UI's job.
//
//  Lenient by rule, like the ChatGPT parser. Written from knowledge of the format and synthetic
//  fixtures; a hand check against a real export is owed (PR follow-ups).
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.75.
//  Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-27 (pre-push review fold) — no positional `index-N` id: a conversation with
//  no `uuid` gets a content-derived one; an unnamed one takes its first user line; a repeated uuid keeps its first
//  conversation. The lenient skips are now pinned like the ChatGPT parser's. Confidence 0.8.

import Foundation

public enum ClaudeExportParser {
    public static func parse(data: Data) throws -> ImportBundle {
        try parse(root: ImportJSON.root(of: data))
    }

    static func parse(root: Any) throws -> ImportBundle {
        guard let array = root as? [Any] else { throw ImportParseError.unexpectedShape }
        let conversations = array.compactMap { ($0 as? [String: Any]).flatMap(conversation(from:)) }
        return ImportBundle(provider: .claude, conversations: ImportJSON.uniqueByID(conversations))
    }

    private static func conversation(from object: [String: Any]) -> ImportedConversation? {
        guard let chat = object["chat_messages"] as? [Any] else { return nil }
        let messages = chat.compactMap { ($0 as? [String: Any]).flatMap(message(from:)) }
        guard !messages.isEmpty else { return nil }
        let title = ImportJSON.nonEmpty(object["name"] as? String)
        let createdAt = ImportDates.iso8601(object["created_at"] as? String)
        return ImportedConversation(
            id: ImportJSON.nonEmpty(object["uuid"] as? String)
                ?? ImportJSON.derivedID(title: title, createdAt: createdAt, messages: messages),
            title: title ?? ImportJSON.titleExcerpt(of: messages),
            createdAt: createdAt,
            messages: messages
        )
    }

    private static func message(from object: [String: Any]) -> ImportedMessage? {
        guard let role = role(object["sender"] as? String) else { return nil }
        let blocks = (object["content"] as? [Any] ?? [])
            .compactMap { $0 as? [String: Any] }
            .filter { $0["type"] as? String == "text" }
            .compactMap { ImportJSON.nonEmpty($0["text"] as? String) }
        guard let text = blocks.isEmpty
            ? ImportJSON.nonEmpty(object["text"] as? String)
            : blocks.joined(separator: "\n\n")
        else { return nil }
        return ImportedMessage(role: role, text: text, createdAt: ImportDates.iso8601(object["created_at"] as? String))
    }

    private static func role(_ raw: String?) -> ImportedRole? {
        switch raw {
        case "human", "user": .user
        case "assistant": .assistant
        default: nil
        }
    }
}
