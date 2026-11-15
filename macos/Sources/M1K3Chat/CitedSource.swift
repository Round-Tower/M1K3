//
//  CitedSource.swift
//  M1K3Chat
//
//  The page a spoken answer cited, for "show me that" and the link chip in voice mode (#839).
//  The URLs come from `ChatMessage.citedURLs`: the ones the app's own "Web sources:" /
//  "Wikipedia sources:" block cited, lifted from tool observations and recorded by the responder
//  (AgentRAGResponder.collectedCitedURLs). Block TEXT is never trusted: a turn can run web_search,
//  get no URLs, and have a model (or an injected page) type its own block. A read's answer cites
//  nothing either (its words came from someone else's text).
//
//  The highlight quote is the first double-quoted passage of five words or more in the answer's
//  own prose (a model quoting the page). It may not be on the page; the page then opens without
//  a highlight.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-15, Confidence 0.8 (the quote heuristic is a first cut,
//  tuned only on hand-written cases). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-11-15 — #839 review: trust `citedURLs`, not block text (forgeable);
//  add `availability` (ready / pending while the sources land / none) and `CitedSourceCache`.
//  Confidence 0.8.

import Foundation

public struct CitedSource: Sendable, Equatable {
    public let url: URL
    public let quote: String?

    /// The words a quote needs to count as a passage, not a scare-quote.
    static let minQuoteWords = 5

    /// What "show me that" can do right now.
    public enum Availability: Sendable, Equatable {
        /// The last answer cited this source.
        case ready(CitedSource)
        /// The last answer is still being written and used a tool that cites; its sources land when it finishes.
        case pending
        /// Nothing to put up: the words are an ordinary turn.
        case none
    }

    /// The cited source of the LAST assistant answer, or nil when that answer cited nothing.
    /// An earlier answer's source does not carry over: "show me that" means the one just given.
    public static func lastAnswer(in messages: [ChatMessage]) -> CitedSource? {
        guard let last = messages.last(where: { $0.role == .assistant }) else { return nil }
        return find(in: last)
    }

    public static func availability(in messages: [ChatMessage]) -> Availability {
        guard let last = messages.last(where: { $0.role == .assistant }) else { return .none }
        if case .streaming = last.status {
            let tools = Set(last.toolsUsed ?? [])
            return tools.contains("web_search") || tools.contains("lookup_fact") ? .pending : .none
        }
        return find(in: last).map(Availability.ready) ?? .none
    }

    public static func find(in message: ChatMessage) -> CitedSource? {
        guard let first = urls(in: message).first else { return nil }
        return CitedSource(url: first, quote: quote(in: body(of: message.text)))
    }

    /// Every http(s) URL the app cited for this message, in order.
    public static func urls(in message: ChatMessage) -> [URL] {
        guard message.role == .assistant, !message.isRead else { return [] }
        return (message.citedURLs ?? []).compactMap { raw in
            guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", url.host != nil
            else { return nil }
            return url
        }
    }

    // MARK: - Quote

    private static var header: Regex<(Substring, Substring)> {
        /(?m)^[ \t]*(Web|Wikipedia) sources:[ \t]*$/
    }

    /// The answer's prose: everything before the sources block.
    private static func body(of text: String) -> String {
        guard let match = text.matches(of: header).last else { return text }
        return String(text[..<match.range.lowerBound])
    }

    private static var quoted: Regex<(Substring, Substring)> {
        /[\u{201C}"]([^\u{201C}\u{201D}"\n]+)[\u{201D}"]/
    }

    private static func quote(in prose: String) -> String? {
        for match in prose.matches(of: quoted) {
            let passage = match.output.1.trimmingCharacters(in: .whitespacesAndNewlines)
            if passage.split(whereSeparator: \.isWhitespace).count >= minQuoteWords { return passage }
        }
        return nil
    }
}

/// Memoises the cited source per FINISHED message id, so a SwiftUI body does not re-parse a message
/// on every pass. A message still streaming is never cached (its sources have not landed).
@MainActor
public final class CitedSourceCache {
    private var found: [UUID: CitedSource?] = [:]

    public init() {}

    public func availability(in messages: [ChatMessage]) -> CitedSource.Availability {
        guard let last = messages.last(where: { $0.role == .assistant }) else { return .none }
        guard case .complete = last.status else { return CitedSource.availability(in: messages) }
        if let hit = found[last.id] { return hit.map(CitedSource.Availability.ready) ?? .none }
        let source = CitedSource.find(in: last)
        found[last.id] = .some(source)
        return source.map(CitedSource.Availability.ready) ?? .none
    }

    /// How many messages are memoised (for tests).
    public var count: Int {
        found.count
    }
}
