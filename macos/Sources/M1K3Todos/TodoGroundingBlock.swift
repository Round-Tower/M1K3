//
//  TodoGroundingBlock.swift
//  M1K3Todos
//
//  The block the responder pastes after WHAT I KNOW ABOUT YOU. Per-turn
//  content, never the cached persona prefix — so a list that changes
//  between turns costs nothing but its own tokens (~10 a line, capped at
//  eight). nil when the list is empty: the prompt is then byte-identical
//  to a build without todos.
//
//  The header tells the model the two things v1 forbids — marking done,
//  adding unasked — because a small model reads a list of chores as an
//  invitation. Bands are MemoryRecency's calm-over-precision stance,
//  copied rather than imported so this target stays chat-free.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-07, Confidence 0.85 (format and
//  ordering pinned; wording awaits the live A/B every grounding block gets).
//  Prior: none (new file).
//  Review: Kev + claude-fable-5.2, 2026-11-13 — `TodoProposalLine.isSpecific`: a title made only of list
//  vocabulary ("Complete open task") is no proposal; `duplicateKey` is the form titles are compared in.
//  Confidence 0.8: the word list is hand-picked from the two live cases plus obvious siblings, not measured.
//

import Foundation

public enum TodoGroundingBlock {
    public static let defaultLimit = 8
    public static let header =
        "OPEN TODOS (the user's own list — mention only when relevant; never mark one done, never add one unasked):"

    /// Overdue first (most overdue leading), then due soonest, then undated
    /// newest first. Only `.open` items are rendered; callers pass what
    /// they have and the block filters.
    public static func render(open: [Todo], now: Date, limit: Int = defaultLimit) -> String? {
        let items = open.filter { $0.state == .open }
        guard !items.isEmpty else { return nil }
        let ordered = items.sorted { a, b in
            switch (a.due, b.due) {
            case let (da?, db?): da != db ? da < db : a.createdAt > b.createdAt
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): a.createdAt > b.createdAt
            }
        }
        let lines = ordered.prefix(limit).map { line(for: $0, now: now) }
        return ([header] + lines).joined(separator: "\n")
    }

    static func line(for todo: Todo, now: Date) -> String {
        var text = "- "
        if let due = todo.due { text += "[\(dueBand(due, now: now))] " }
        text += todo.title
        // nil = a loopback client that never sent `initialize` (the LAN scope
        // cannot propose at all), so the honest label is an unnamed agent.
        if case let .visitor(clientName) = todo.source {
            text += " (from \(clientName ?? "an unnamed agent"))"
        }
        return text
    }

    /// Whole 86 400-second days off the supplied clock — deterministic,
    /// locale-free, like MemoryRecency.
    public static func dueBand(_ due: Date, now: Date) -> String {
        let seconds = due.timeIntervalSince(now)
        if seconds < 0 {
            let days = max(1, Int(-seconds / 86400))
            return days == 1 ? "overdue 1 day" : "overdue \(days) days"
        }
        let days = Int(seconds / 86400)
        switch days {
        case 0: return "due today"
        case 1: return "due tomorrow"
        case 2 ..< 14: return "due in \(days) days"
        default: return "due in \(days / 7) weeks"
        }
    }
}

/// The heartbeat's proposal channel: the narrative prompt may end with ONE
/// `TODO: <title>` line. Extract it BEFORE NarrativeGuard sees the text
/// (the guard would count it against length) and hand the title to the
/// ceiling-gated proposal path. Only the LAST line is read — a small model
/// that scatters TODOs through its prose gets none of them.
public enum TodoProposalLine {
    public static let maxTitleLength = 120

    public static func extract(from narrative: String) -> (narrative: String, title: String?) {
        var lines = narrative.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        guard let last = lines.last else { return (narrative, nil) }
        let stripped = last.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-*• "))
        guard stripped.lowercased().hasPrefix("todo:") else { return (narrative, nil) }
        lines.removeLast()
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var title = stripped.dropFirst("todo:".count).trimmingCharacters(in: .whitespaces)
        while title.hasSuffix(".") {
            title.removeLast()
        }
        guard !title.isEmpty, title.count <= maxTitleLength, isSpecific(title) else { return (body, nil) }
        return (body, title)
    }

    /// Whether a proposed title names a task at all. The digest says "Todos: 1
    /// open" and a small model answers `TODO: Complete open task`: every word
    /// there is about the LIST, none about the task. A title needs at least one
    /// word that is not list vocabulary.
    public static func isSpecific(_ title: String) -> Bool {
        titleWords(title).contains { !listVocabulary.contains($0) }
    }

    /// The form two titles are compared in: case, punctuation and spacing do not
    /// make a different task ("Renew passport." is "renew  Passport").
    /// Marks INSIDE a word are part of the task: "Learn C++" is not "Learn C#".
    public static func duplicateKey(_ title: String) -> String {
        title.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\"'()[]“”‘’")) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func titleWords(_ title: String) -> [String] {
        title.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Words that describe a todo list rather than anything on it.
    private static let listVocabulary: Set<String> = [
        "complete", "finish", "do", "done", "handle", "address", "resolve", "review", "check", "close", "clear",
        "the", "a", "an", "your", "my", "this", "that", "all", "any", "some", "one", "up", "on", "of", "to", "it",
        "open", "pending", "overdue", "outstanding", "remaining", "unfinished", "incomplete", "new", "next",
        "task", "tasks", "todo", "todos", "item", "items", "list", "thing", "things", "work", "stuff",
        "follow", "followup", "reminder", "reminders",
    ]
}
