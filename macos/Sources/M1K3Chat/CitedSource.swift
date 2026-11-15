//
//  CitedSource.swift
//  M1K3Chat
//
//  The page a spoken answer cited, for "show me that" and the link chip in voice mode (#839).
//  No new record: cited URLs already live in the answer's text as the deterministic
//  "Web sources:" / "Wikipedia sources:" block the app appends (lifted from tool observations,
//  never the model; AgentRAGResponder+Provenance). This reads that block back, and trusts it
//  only when the turn really ran the matching tool (`toolsUsed`): a block a model typed itself
//  cites nothing, and neither does a read's answer (its words came from someone else's text).
//
//  The highlight quote is the first double-quoted passage of five words or more in the answer's
//  own prose (a model quoting the page). It may not be on the page; the page then opens without
//  a highlight.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-15, Confidence 0.8 (the block format is pinned by the
//  provenance tests; the quote heuristic is a first cut, tuned only on hand-written cases).
//  Prior: none (new file).

import Foundation

public struct CitedSource: Sendable, Equatable {
    public let url: URL
    public let quote: String?

    /// The words a quote needs to count as a passage, not a scare-quote.
    static let minQuoteWords = 5

    /// The cited source of the LAST assistant answer, or nil when that answer cited nothing.
    /// An earlier answer's source does not carry over: "show me that" means the one just given.
    public static func lastAnswer(in messages: [ChatMessage]) -> CitedSource? {
        guard let last = messages.last(where: { $0.role == .assistant }) else { return nil }
        return find(in: last)
    }

    public static func find(in message: ChatMessage) -> CitedSource? {
        guard let first = urls(in: message).first else { return nil }
        return CitedSource(url: first, quote: quote(in: body(of: message.text)))
    }

    /// Every http(s) URL in the message's trusted sources block, in order.
    public static func urls(in message: ChatMessage) -> [URL] {
        guard message.role == .assistant, !message.isRead else { return [] }
        let tools = Set(message.toolsUsed ?? [])
        guard let block = lastBlock(in: message.text), tools.contains(block.tool) else { return [] }
        return block.urls
    }

    // MARK: - Parsing

    private struct Block {
        let tool: String
        let urls: [URL]
        let headerStart: String.Index
    }

    private static var header: Regex<(Substring, Substring)> {
        /(?m)^[ \t]*(Web|Wikipedia) sources:[ \t]*$/
    }

    private static func lastBlock(in text: String) -> Block? {
        guard let match = text.matches(of: header).last else { return nil }
        let tool = match.output.1 == "Web" ? "web_search" : "lookup_fact"
        let rest = text[match.range.upperBound...]
        var urls: [URL] = []
        for line in rest.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("•") else { break }
            let raw = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", url.host != nil
            else { continue }
            urls.append(url)
        }
        return Block(tool: tool, urls: urls, headerStart: match.range.lowerBound)
    }

    /// The answer's prose: everything before the sources block.
    private static func body(of text: String) -> String {
        guard let block = lastBlock(in: text) else { return text }
        return String(text[..<block.headerStart])
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
