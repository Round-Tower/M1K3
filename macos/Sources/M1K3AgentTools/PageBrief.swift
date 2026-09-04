//
//  PageBrief.swift
//  M1K3AgentTools
//
//  What open_link hands the model about the page it just opened. Before this,
//  the tool returned one line — "Opened m1k3.app in the review panel." — and
//  the model, holding nothing, described the page anyway: "a static page with
//  my name and a thin banner saying coming soon" (Lil, 2026-09-04; Kev's dislike
//  with the comment "we didn't pick it up… webview analysis needs to be
//  improved"). The brief is the fix at the source: title and description from
//  the head the text extractor throws away, the site's own note for AI agents
//  (llms.txt at the origin — the one universal agent file), a first chunk of
//  readable text through the same extractor fetch_page uses — or, when the
//  page can't be read, a sentence the model cannot misread: do not describe it.
//
//  Pure: HTML in, text out. The fetches live in OpenLinkTool; the caps keep one
//  opened page from eating the turn's budget.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-04, Confidence 0.85 (the shapes are
//  pinned by tests; whether a 4B brain stops narrating on "Do not describe the
//  page" is a live A/B, not a proof). Prior: Unknown.

import Foundation

/// What could be gathered about an opened page. `html` nil with a `failure` set
/// means the page itself couldn't be fetched; `llmsText` is optional by nature.
public struct PageBriefSources: Sendable, Equatable {
    public var html: String?
    public var llmsText: String?
    public var failure: String?

    public init(html: String? = nil, llmsText: String? = nil, failure: String? = nil) {
        self.html = html
        self.llmsText = llmsText
        self.failure = failure
    }
}

public enum PageBrief {
    static let openedPrefix = "Opened"
    static let doNotDescribe = "Do not describe the page"

    /// `<title>` — entity-decoded, whitespace-collapsed; nil when absent/empty.
    static func title(from html: String) -> String? {
        firstMatch(in: html, pattern: "(?is)<title[^>]*>(.*?)</title>")
            .map { collapse(HTMLTextExtractor.decodeEntities($0)) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// `<meta name="description" content="…">` in either attribute order.
    static func metaDescription(from html: String) -> String? {
        let patterns = [
            "(?is)<meta\\b[^>]*\\bname\\s*=\\s*[\"']description[\"'][^>]*\\bcontent\\s*=\\s*[\"']([^\"']*)[\"']",
            "(?is)<meta\\b[^>]*\\bcontent\\s*=\\s*[\"']([^\"']*)[\"'][^>]*\\bname\\s*=\\s*[\"']description[\"']",
        ]
        for pattern in patterns {
            if let raw = firstMatch(in: html, pattern: pattern) {
                let text = collapse(HTMLTextExtractor.decodeEntities(raw))
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    /// The agent file lives at the site ORIGIN (`/llms.txt`), never under the
    /// page's path — same scheme/host/port, no query.
    static func llmsURL(for url: URL) -> URL? {
        var parts = URLComponents()
        parts.scheme = url.scheme
        parts.host = url.host
        parts.port = url.port
        parts.path = "/llms.txt"
        return parts.url
    }

    /// A served llms.txt is only usable if it's text: single-page apps answer
    /// every unknown path with their HTML shell, which would put the app's
    /// markup where the site's description should be.
    static func usableLLMSText(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let head = trimmed.prefix(512).lowercased()
        guard !head.hasPrefix("<!doctype"), !head.contains("<html"), !head.contains("<head") else { return nil }
        return trimmed
    }

    /// The text the model reads back from open_link.
    public static func render(
        url: URL, sources: PageBriefSources, textBudget: Int = 900, llmsBudget: Int = 600
    ) -> String {
        let host = url.host ?? url.absoluteString
        if let failure = sources.failure, sources.html == nil {
            return "\(openedPrefix) \(host) in the review panel, but could not read its content (\(failure)). "
                + "\(doNotDescribe) — tell the user it is open beside the chat and that you could not read it."
        }
        var lines = ["\(openedPrefix) \(host) in the review panel."]
        let html = sources.html ?? ""
        if let title = title(from: html) { lines.append("Title: \(title)") }
        if let description = metaDescription(from: html) { lines.append("Description: \(description)") }
        if let llms = sources.llmsText.flatMap(usableLLMSText) {
            lines.append("The site's own note for AI agents (llms.txt): \(cap(collapse(llms), to: llmsBudget))")
        }
        let text = HTMLTextExtractor.text(from: html)
        if text.isEmpty {
            lines.append(
                "It has no readable text (it may need JavaScript). \(doNotDescribe) beyond its title — "
                    + "tell the user it is open beside the chat."
            )
        } else {
            lines.append("Page text: \(cap(text, to: textBudget))")
        }
        return lines.joined(separator: "\n")
    }

    private static func cap(_ text: String, to budget: Int) -> String {
        guard text.count > budget else { return text }
        return text.prefix(budget).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}
