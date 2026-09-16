//
//  IntentInputs.swift
//  M1K3Chat
//
//  Pure input validation + title derivation for the macOS App Intents
//  (Ask · Speak · Remember · SearchKnowledge · RecallMemory · ListTodos ·
//  ProposeTodo · OpenVoiceMode). The intents' perform() bodies are app-glue
//  (verify-by-launch); this is the small testable core they call before
//  touching any service — trim/reject-empty, and derive a memory title from
//  free text when the user didn't supply one (voice-first ergonomics).
//
//  Signed: Kev + claude-opus-4-8, 2026-06-17, Confidence 0.85, Prior: Unknown
//

import Foundation

public enum IntentInput {
    /// A required free-text field arrived empty (or whitespace-only). Conforms to
    /// `LocalizedError` so an App Intent can surface it directly to Siri/Shortcuts.
    public struct EmptyInput: Error, LocalizedError, Equatable {
        public let field: String
        public init(field: String) {
            self.field = field
        }

        public var errorDescription: String? {
            "Please provide a \(field) for M1K3."
        }
    }

    /// Upper bound on a derived memory title; longer first-sentences truncate at a
    /// word boundary with an ellipsis.
    public static let titleCharacterCap = 60

    /// Trim + require a non-empty question. Throws `EmptyInput(field: "question")`.
    public static func askQuestion(_ raw: String) throws -> String {
        try requireNonEmpty(raw, field: "question")
    }

    /// Trim + require non-empty text to speak. Throws `EmptyInput(field: "text")`.
    public static func speakText(_ raw: String) throws -> String {
        try requireNonEmpty(raw, field: "text")
    }

    /// Trim + require a non-empty memory body. Throws `EmptyInput(field: "text")`.
    public static func rememberText(_ raw: String) throws -> String {
        try requireNonEmpty(raw, field: "text")
    }

    /// Resolve a memory title: a non-empty explicit title wins (trimmed); otherwise
    /// derive a short handle from the body's first sentence.
    public static func rememberTitle(from text: String, explicit: String? = nil) -> String {
        if let explicit {
            let trimmed = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return derivedTitle(from: text)
    }

    /// Trim + require a non-empty search query. Throws `EmptyInput(field: "query")`.
    public static func searchQuery(_ raw: String) throws -> String {
        try requireNonEmpty(raw, field: "query")
    }

    /// Trim + require a non-empty recall query. Throws `EmptyInput(field: "query")`.
    public static func recallQuery(_ raw: String) throws -> String {
        try requireNonEmpty(raw, field: "query")
    }

    /// Trim + require a non-empty todo title. Throws `EmptyInput(field: "title")`.
    public static func todoTitle(_ raw: String) throws -> String {
        try requireNonEmpty(raw, field: "title")
    }

    // MARK: - Internals

    private static func requireNonEmpty(_ raw: String, field: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EmptyInput(field: field) }
        return trimmed
    }

    /// First sentence (up to the first `.`/`!`/`?`), whitespace collapsed, truncated
    /// at a word boundary. Degrades to a stable "Memory" for content-less input.
    static func derivedTitle(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstSentence = trimmed.prefix { !".!?".contains($0) }
        let collapsed = firstSentence
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return "Memory" }
        return truncateAtWord(collapsed, cap: titleCharacterCap)
    }

    private static func truncateAtWord(_ text: String, cap: Int) -> String {
        guard text.count > cap else { return text }
        let hardCut = String(text.prefix(cap))
        if let lastSpace = hardCut.lastIndex(of: " ") {
            let head = hardCut[..<lastSpace].trimmingCharacters(in: .whitespaces)
            if !head.isEmpty { return head + "…" }
        }
        return hardCut + "…"
    }
}
