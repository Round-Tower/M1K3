//
//  ToolDispatch.swift
//  M1K3Chat
//
//  Router-invoked tools (Kev, 2026-09-26: "use it to invoke tools outside of the
//  inference loop"). A Mini tool turn cost ~50 s: the model decided on a tool,
//  called it, then a second generation synthesised the answer, and none of it
//  streamed. Here the app runs ONE read-only tool itself and the plain-chat
//  route answers with the result in hand: one streamed generation, and no tool
//  palette in the prompt.
//
//  This file is the pure half: which tools may be dispatched at all (read-only,
//  one text argument), how a pick becomes the tool's input, and how the result
//  reads in the prompt. Anything that acts on the Mac (scripts, the review panel,
//  a deep dive) or can't be planned safely returns nil, and the turn takes the
//  agent loop exactly as before.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-26, Confidence 0.8 (pure and pinned; the
//  pick itself and the live gain are measured separately). Prior: Unknown.
//

import Foundation
import M1K3Agent

/// A tool choice for one turn: a tool name ("none" when nothing is needed) and
/// the query, URL or topic it should get. Empty query = use the user's words.
public struct ToolPick: Sendable, Equatable {
    public let tool: String
    public let query: String

    public init(tool: String, query: String) {
        self.tool = tool
        self.query = query
    }

    public static let noTool = "none"
    public static let action = "action"
}

public enum ToolDispatch {
    /// Read-only tools with one text argument (or none). Nothing here writes,
    /// runs, opens or delegates anything.
    public static let dispatchable: Set<String> = [
        "datetime", "battery_status", "system_status", "calendar_peek", "current_location",
        "recent_activity", "search_knowledge", "list_documents", "web_search", "lookup_fact", "fetch_page",
    ]

    /// Every name a picker may answer: the dispatchable tools, `none` (plain chat)
    /// and `action` (anything that acts: the agent turn).
    public static let pickerChoices: [String] = dispatchable.sorted() + [ToolPick.noTool, ToolPick.action]

    /// What the picker is told, then the menu. Measured on Mini (scratch/dispatch-spike):
    /// the "well-known facts need no tool" line is what stops a web search for a capital.
    public static let pickerInstructions = """
    You route a user's message to at most one tool. Reply with the tool's name and, for a \
    search or lookup, the query to use (for fetch_page, the URL). Pick none when the message \
    can be answered from general knowledge, reasoning, writing, maths, code, or conversation. \
    Well-known, stable facts (capital cities, famous authors, basic science, history) need no \
    tool: pick none. Writing or explaining code is none.
    """

    static let menuLines: [String: String] = [
        "datetime": "the current date or time",
        "battery_status": "this device's battery level",
        "system_status": "this Mac's CPU, memory or disk",
        "calendar_peek": "the user's calendar events",
        "current_location": "where the user is now",
        "recent_activity": "the user's recent chats, todos, activity or usage patterns with the assistant (busiest days, what we talked about)",
        "search_knowledge": "the user's own documents, notes, files or recorded calls",
        "list_documents": "a list of the user's stored documents",
        "web_search": "anything current, recent or upcoming, or the newest or latest of anything: news, prices, weather, results, releases",
        "lookup_fact": "an obscure or changeable fact from a reference source",
        "fetch_page": "read a specific web page or URL",
    ]

    /// The picker's menu: one line per dispatchable tool on offer, then none and action.
    public static func menu(palette: [any AgentTool]) -> String {
        let offered = palette.map(\.name).filter { dispatchable.contains($0) }
        let lines = offered.compactMap { name in menuLines[name].map { "\(name): \($0)" } }
        return (lines + [
            "\(ToolPick.action): running code or a command on this Mac, changing files, opening something, or a long research task",
            "\(ToolPick.noTool): none of the above is needed",
        ]).joined(separator: "\n")
    }

    /// The most of one tool's output the prompt carries (Mini's window is 4,096 tokens).
    public static let observationBudget = 2400

    public struct Plan: @unchecked Sendable {
        public let tool: any AgentTool
        public let input: [String: String]
    }

    /// The call to make for this pick, or nil when the turn belongs to the agent.
    public static func plan(_ pick: ToolPick, palette: [any AgentTool], question: String) -> Plan? {
        guard dispatchable.contains(pick.tool),
              let tool = palette.first(where: { $0.name == pick.tool })
        else { return nil }
        let query = pick.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parameter = tool.parameters.first?.name else { return Plan(tool: tool, input: [:]) }
        switch pick.tool {
        case "fetch_page":
            guard let url = webURL(query) ?? webURL(question) else { return nil }
            return Plan(tool: tool, input: [parameter: url])
        case "recent_activity", "list_documents":
            // Optional filters: absent means the tool's own default.
            return Plan(tool: tool, input: query.isEmpty ? [:] : [parameter: query])
        default:
            return Plan(tool: tool, input: [parameter: query.isEmpty ? question : query])
        }
    }

    /// A search that found nothing (the tools' own phrasing). Such a result is not
    /// carried into the prompt: a "found nothing" beside a well-known fact is how a
    /// small model comes to disown what it knows.
    public static func isEmptyResult(_ output: String) -> Bool {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || emptyResultPrefixes.contains { text.hasPrefix($0) }
    }

    static let emptyResultPrefixes = [
        "No results for", "Nothing relevant in stored knowledge", "No web results for", "No Wikipedia article found",
    ]

    /// How the result reads in the plain turn's prompt: named, fresh, bounded.
    public static func observationBlock(tool: String, output: String) -> String {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.count > observationBudget
            ? String(trimmed.prefix(observationBudget)) + " …"
            : trimmed
        return "WHAT \(tool) RETURNED JUST NOW (live, for this question):\n\(body)"
    }

    /// An http(s) URL in `text`, or a bare domain made into one; nil when none.
    static func webURL(_ text: String) -> String? {
        let pattern = #"(https?://[^\s"'<>]+)|\b((?:[a-z0-9-]+\.)+[a-z]{2,})(/[^\s"'<>]*)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text)
        else { return nil }
        let found = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)"))
        return found.lowercased().hasPrefix("http") ? found : "https://" + found
    }
}
