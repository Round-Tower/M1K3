//
//  ResponderActivity.swift
//  M1K3Chat
//
//  What the responder is doing while no tokens are streaming — the cover for
//  the agent loop's silence. The labeler doubles as the privacy surface: a
//  web search always shows its query, so nothing leaves the device invisibly.
//
//  Signed: Kev + claude-fable-5, 2026-06-09, Confidence 0.85, Prior: Unknown

import Foundation

/// A progress signal from the responder, shown on the in-flight message.
public enum ResponderActivity: Sendable, Equatable {
    case retrieving
    case thinking(iteration: Int)
    case usingTool(name: String, argument: String)
}

/// Pure activity → user-facing copy.
public enum ActivityLabeler {
    private static let queryCap = 40

    public static func label(for activity: ResponderActivity) -> String {
        switch activity {
        case .retrieving:
            // Deliberately NOT "…your knowledge": the every-turn RAG phase used
            // to read like the search_knowledge tool, so tool calls looked like
            // they fired on every turn when they hadn't (Kev, 2026-08-16). A
            // self-action verb keeps the phase and the tool distinguishable.
            "Recalling what I know…"
        case .thinking:
            "Thinking…"
        case let .usingTool(name, argument):
            toolLabel(name: name, argument: argument)
        }
    }

    /// The transcript's persisted provenance line ("Used web search · date &
    /// time") — pinned here rather than composed in the View so the product
    /// string is testable.
    public static func traceLabel(for tools: [String]) -> String {
        "Used " + tools.map { displayName(forTool: $0) }.joined(separator: " · ")
    }

    /// Short noun for a tool in the transcript's persisted trace
    /// ("Used web search · date & time"). Unknown tools humanize
    /// (underscores → spaces) rather than leak snake_case into the UI.
    public static func displayName(forTool name: String) -> String {
        switch name {
        case "web_search": "web search"
        case "search_knowledge": "knowledge search"
        case "fetch_page": "web page"
        case "lookup_fact": "fact lookup"
        case "datetime": "date & time"
        case "system_status": "system status"
        case "delegate_deep": "deep dive"
        case "list_documents": "documents"
        case "get_document": "document"
        case "open_link": "link"
        default: name.replacingOccurrences(of: "_", with: " ")
        }
    }

    private static func toolLabel(name: String, argument: String) -> String {
        switch name {
        case "web_search":
            "Searching the web for “\(truncate(argument))”…"
        case "fetch_page":
            "Reading \(URL(string: argument)?.host() ?? "a web page")…"
        case "search_knowledge":
            "Searching your knowledge…"
        case "datetime":
            "Checking the date & time…"
        case "system_status":
            "Checking system status…"
        default:
            "Using \(name)…"
        }
    }

    private static func truncate(_ query: String) -> String {
        guard query.count > queryCap else { return query }
        return query.prefix(queryCap).trimmingCharacters(in: .whitespaces) + "…"
    }
}
