//
//  ResponderActivity.swift
//  M1K3Chat
//
//  What the responder is doing while no tokens are streaming — the cover for
//  the agent loop’s silence. The labeler doubles as the privacy surface: a
//  web search always shows its query, so nothing leaves the device invisibly.
//
//  Signed: Kev + claude-fable-5, 2026-06-09, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-opus-4-6, 2026-09-22 — live tool labels for 6 tools that
//  fell through to the raw default; default fallback humanises with displayName;
//  tool trace footer now visible during streaming, not just after. Confidence 0.85.

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
            "Recalling what I know\u{2026}"
        case .thinking:
            "Thinking\u{2026}"
        case let .usingTool(name, argument):
            toolLabel(name: name, argument: argument)
        }
    }

    /// The transcript's persisted provenance line ("Used web search \u{00B7} date &
    /// time") -- pinned here rather than composed in the View so the product
    /// string is testable.
    public static func traceLabel(for tools: [String]) -> String {
        "Used " + tools.map { displayName(forTool: $0) }.joined(separator: " \u{00B7} ")
    }

    /// Short noun for a tool in the transcript's persisted trace
    /// ("Used web search \u{00B7} date & time"). Unknown tools humanize
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
        case "recent_activity": "recent activity"
        default: name.replacingOccurrences(of: "_", with: " ")
        }
    }

    private static func toolLabel(name: String, argument: String) -> String {
        switch name {
        case "web_search":
            "Searching the web for \u{201C}\(truncate(argument))\u{201D}\u{2026}"
        case "fetch_page":
            "Reading \(URL(string: argument)?.host() ?? "a web page")\u{2026}"
        case "search_knowledge":
            "Searching your knowledge\u{2026}"
        case "datetime":
            "Checking the date & time\u{2026}"
        case "system_status":
            "Checking system status\u{2026}"
        case "delegate_deep":
            "Starting a deep dive\u{2026}"
        case "list_documents":
            "Scanning your documents\u{2026}"
        case "get_document":
            "Opening a document\u{2026}"
        case "open_link":
            "Opening a link\u{2026}"
        case "lookup_fact":
            "Looking that up\u{2026}"
        case "recent_activity":
            "Looking back over the week\u{2026}"
        default:
            "Using \(displayName(forTool: name))\u{2026}"
        }
    }

    private static func truncate(_ query: String) -> String {
        guard query.count > queryCap else { return query }
        return query.prefix(queryCap).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }
}
