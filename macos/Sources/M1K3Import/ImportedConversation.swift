//
//  ImportedConversation.swift
//  M1K3Import
//
//  The one model every importer produces (#711): a ChatGPT or Claude data export becomes
//  conversations of user / assistant messages; another M1K3's OKF folder becomes facts (it
//  already is facts). Two renderings serve the two destinations — `chatTurns` for the memory
//  distiller, `pages` for the knowledge corpus that files and cites the conversation.
//
//  Everything here is parsed on the Mac from a file the user dropped: no network, no sign-in.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85.
//  Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-27 (pre-push review fold) — a conversation with no id gets one DERIVED from
//  what it says (`ImportJSON.derivedID`), never from its position in the file: the id is the filed conversation's
//  dedupe key across exports, and `index-3` named a different chat in the next export. An untitled conversation
//  takes its first user line as the title, and a repeated id keeps its first conversation. Confidence 0.85.

import CryptoKit
import Foundation
import M1K3Chat
import M1K3Knowledge

/// Where an import came from. The raw values PERSIST: they are the middle of every imported
/// row's `import/<provider>/<date>` source tag, so renaming one orphans its rows.
public enum ImportProvider: String, Sendable, CaseIterable, Codable {
    case chatgpt
    case claude
    /// Another M1K3's OKF memory export (ADR 0003).
    case m1k3
}

public enum ImportedRole: Sendable, Equatable {
    case user
    case assistant

    /// The label a filed conversation carries on each line.
    var label: String {
        switch self {
        case .user: "User"
        case .assistant: "Assistant"
        }
    }
}

public struct ImportedMessage: Sendable, Equatable {
    public let role: ImportedRole
    public let text: String
    public let createdAt: Date?

    public init(role: ImportedRole, text: String, createdAt: Date? = nil) {
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

public struct ImportedConversation: Sendable, Equatable, Identifiable {
    /// The provider's own conversation id, or one derived from the conversation's content when the
    /// export carries none (`ImportJSON.derivedID`): the dedupe key of the filed knowledge item.
    public let id: String
    public let title: String
    public let createdAt: Date?
    public let messages: [ImportedMessage]

    public init(id: String, title: String, createdAt: Date?, messages: [ImportedMessage]) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.messages = messages
    }

    /// What the memory distiller reads, in order.
    public var chatTurns: [ChatTurn] {
        messages.map { ChatTurn(role: $0.role == .user ? .user : .assistant, text: $0.text) }
    }

    /// What the corpus files: ONE page, one "User: …" / "Assistant: …" line per message.
    /// One page on purpose — DocumentChunker drops a line that repeats on 40 % of pages as a
    /// running header, which would eat per-page role labels.
    public var pages: [DocumentPage] {
        [DocumentPage(pageNumber: 1, text: messages.map { "\($0.role.label): \($0.text)" }.joined(separator: "\n"))]
    }
}

/// A fact that arrives already stated (an OKF file from another M1K3), so it skips the
/// distiller; the import's source tag still marks it as this import's.
public struct ImportedFact: Sendable, Equatable {
    public let kind: DistilledFactKind
    public let text: String
    public let title: String?
    public let createdAt: Date?
    /// The `source` the exporting M1K3 recorded ("distilled", "mcp:remember", …).
    public let originalSource: String

    public init(kind: DistilledFactKind, text: String, title: String?, createdAt: Date?, originalSource: String) {
        self.kind = kind
        self.text = text
        self.title = title
        self.createdAt = createdAt
        self.originalSource = originalSource
    }
}

/// One parsed export.
public struct ImportBundle: Sendable, Equatable {
    public let provider: ImportProvider
    public let conversations: [ImportedConversation]
    public let facts: [ImportedFact]

    public init(provider: ImportProvider, conversations: [ImportedConversation] = [], facts: [ImportedFact] = []) {
        self.provider = provider
        self.conversations = conversations
        self.facts = facts
    }

    /// Oldest first (undated first; ties keep export order), the order an import commits in, so
    /// a later restatement supersedes an earlier one rather than the reverse.
    public var chronologicalConversations: [ImportedConversation] {
        conversations.enumerated()
            .sorted { lhs, rhs in
                let left = lhs.element.createdAt ?? .distantPast
                let right = rhs.element.createdAt ?? .distantPast
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
    }
}

public enum ImportParseError: Error, Equatable, Sendable {
    /// The file is not JSON at all.
    case notJSON
    /// JSON, but the root is not the array an export's `conversations.json` is.
    case unexpectedShape
    /// Neither a ChatGPT nor a Claude export.
    case unrecognisedFormat
}

// MARK: - Shared parsing helpers

enum ImportJSON {
    /// The parsed root of an export file. Whole-file: an export is tens of MB at most.
    static func root(of data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ImportParseError.notJSON
        }
    }

    static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// A stable id for a conversation whose export names none: a hash of its title, date and first
    /// message, never its position in the file. The id is the filed conversation's dedupe key across
    /// exports (`ImportSourceTag.conversationSourceRef`), so a positional id would make a later
    /// export's different chat at the same index read as "already filed".
    static func derivedID(title: String?, createdAt: Date?, messages: [ImportedMessage]) -> String {
        let seed = [
            title ?? "", createdAt.map { String($0.timeIntervalSince1970) } ?? "", messages.first?.text ?? "",
        ].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(seed.utf8))
        return "derived-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The title an untitled conversation shows: its first user line (or first line), cut at a word
    /// boundary — never a raw id, which the cited-knowledge UI would show and every chunk would embed.
    static func titleExcerpt(of messages: [ImportedMessage]) -> String {
        let text = (messages.first { $0.role == .user } ?? messages.first)?.text ?? ""
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        guard line.count > maxTitleLength else { return line }
        let prefix = line.prefix(maxTitleLength)
        let cut = prefix.lastIndex(of: " ").map { prefix[..<$0] } ?? prefix
        return String(cut) + "…"
    }

    static let maxTitleLength = 60

    /// The first conversation for each id, in export order: a repeated id names one conversation.
    static func uniqueByID(_ conversations: [ImportedConversation]) -> [ImportedConversation] {
        var seen: Set<String> = []
        return conversations.filter { seen.insert($0.id).inserted }
    }
}

enum ImportDates {
    /// Seconds since 1970 (ChatGPT's `create_time`); nil for null, absent, or non-numbers.
    static func epoch(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue)
    }

    /// ISO 8601 with or without fractional seconds (Claude writes microseconds; OKF whole seconds).
    static func iso8601(_ value: String?) -> Date? {
        guard let value = ImportJSON.nonEmpty(value) else { return nil }
        return (try? Date.ISO8601FormatStyle().parse(value))
            ?? (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
    }
}
