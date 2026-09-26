//
//  CallSummaryParser.swift
//  M1K3Calls
//
//  Turns a model's free-text deep-analysis response into a structured CallSummary.
//  Pure + lenient: recognises "Overview / Key points / Action items" headers
//  (case-insensitive) and routes bullet lines under each; any text before the
//  first header (or a response with no headers at all) becomes the overview, so a
//  model that ignores the format still yields something useful rather than nothing.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.8, Prior: Unknown
//  Review: Kev + claude-opus-5-5, 2026-09-26 — headers in markdown dress (`# ACTION ITEMS:`,
//  `## Key points`, `**Overview:**`) are headers: Mini writes them, and unrecognised they folded
//  every section into the overview (action items came back empty). Confidence 0.85.
import Foundation

public struct CallSummaryParser: Sendable {
    public init() {}

    private enum Section { case overview, keyPoints, actionItems, preamble }

    public func parse(_ text: String) -> CallSummary {
        var overview: [String] = []
        var keyPoints: [String] = []
        var actionItems: [String] = []
        var section: Section = .preamble

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if let (header, inline) = Self.header(in: line) {
                section = header
                if !inline.isEmpty { route(inline, into: header, &overview, &keyPoints, &actionItems) }
                continue
            }
            route(line, into: section, &overview, &keyPoints, &actionItems)
        }

        return CallSummary(
            overview: overview.joined(separator: " ").trimmingCharacters(in: .whitespaces),
            keyPoints: keyPoints,
            actionItems: actionItems
        )
    }

    private func route(
        _ line: String,
        into section: Section,
        _ overview: inout [String],
        _ keyPoints: inout [String],
        _ actionItems: inout [String]
    ) {
        switch section {
        case .overview, .preamble: overview.append(Self.stripBullet(line))
        case .keyPoints: keyPoints.append(Self.stripBullet(line))
        case .actionItems: actionItems.append(Self.stripBullet(line))
        }
    }

    /// Recognise a header line, returning the section and any inline content after
    /// the colon (e.g. "Overview: the call went well" → (.overview, "the call…")).
    private static func header(in rawLine: String) -> (Section, String)? {
        let line = undecorated(rawLine)
        let lower = line.lowercased()
        let headers: [(String, Section)] = [
            ("overview", .overview),
            ("summary", .overview),
            ("key points", .keyPoints),
            ("key point", .keyPoints),
            ("action items", .actionItems),
            ("action item", .actionItems),
            ("actions", .actionItems),
        ]
        for (label, section) in headers where lower == label || lower.hasPrefix(label + ":") {
            let inline = line.dropFirst(label.count).drop(while: { $0 == ":" })
                .trimmingCharacters(in: .whitespaces)
            return (section, inline)
        }
        return nil
    }

    /// Markdown a model wraps a header in: `# X:`, `## X`, `**X:**`, `**X**:`.
    /// Only a leading `#` run and bold markers around the label are removed, so
    /// the header match stays exact.
    private static func undecorated(_ line: String) -> String {
        let s = Substring(line).drop(while: { $0 == "#" }).drop(while: { $0 == " " })
        let marker = String(s.prefix(2))
        guard marker == "**" || marker == "__" else { return String(s) }
        let body = s.dropFirst(2)
        guard let close = body.range(of: marker) else { return String(body) }
        return String(body[..<close.lowerBound] + body[close.upperBound...])
    }

    /// Strip a leading list marker ("- ", "* ", "• ", "1. ") if present.
    private static func stripBullet(_ line: String) -> String {
        var s = Substring(line)
        if let first = s.first, "-*•".contains(first) {
            s = s.dropFirst().drop(while: { $0 == " " })
        } else {
            // numbered: leading digits + . or )
            let digits = s.prefix(while: { $0.isNumber })
            if !digits.isEmpty {
                let rest = s.dropFirst(digits.count)
                if let m = rest.first, m == "." || m == ")" {
                    s = rest.dropFirst().drop(while: { $0 == " " })
                }
            }
        }
        return String(s).trimmingCharacters(in: .whitespaces)
    }
}
