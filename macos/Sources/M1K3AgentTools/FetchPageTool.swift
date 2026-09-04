//
//  FetchPageTool.swift
//  M1K3AgentTools
//
//  web_search finds pages; fetch_page READS one — the difference between a
//  link list and an actual answer (the Boston-weather follow-up). Pure
//  HTMLTextExtractor turns a page into readable text; the tool guards the
//  scheme (http/https only), sends browser headers, caps the output so a
//  small model's context survives, and reports failures as observations the
//  loop can recover from.
//
//  Privacy: fetching a page is egress, same as searching — the app only
//  injects this tool alongside web_search behind the same Settings toggle,
//  and the activity label shows which page is being read.
//
//  Signed: Kev + claude-fable-5, 2026-06-10, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-opus-4-8, 2026-06-30, Confidence 0.9 — extracted
//  validatedURL/pageRequest helpers + readablePage(at:) (a text-or-nil core)
//  so web_search's deterministic deepen can read a page without the tool's
//  agent-facing error strings. execute() behaviour is unchanged.
//  Review: Kev + claude-fable-5.1, 2026-09-04 — the description no longer presumes a search
//  came first: an address the user gives is read directly (live replay: it was searched for).

import Foundation
import M1K3Agent
import M1K3Preview
import os

/// Pure HTML → readable text: drop head/script/style/comments, turn block
/// boundaries into line breaks, strip tags, decode entities, tidy whitespace.
enum HTMLTextExtractor {
    static func text(from html: String) -> String {
        var work = html
        let removals = [
            "(?is)<script\\b.*?</script>",
            "(?is)<style\\b.*?</style>",
            "(?is)<head\\b.*?</head>",
            // Page chrome eats the output cap before content starts (seen live).
            "(?is)<nav\\b.*?</nav>",
            "(?is)<header\\b.*?</header>",
            "(?is)<footer\\b.*?</footer>",
            "(?s)<!--.*?-->",
        ]
        for pattern in removals {
            work = work.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        // Block boundaries → newlines; td/th too, so adjacent cells don't run together.
        work = work.replacingOccurrences(
            of: "(?i)</(p|div|h[1-6]|li|tr|td|th|section|article|ul|ol|table)>|<br[^>]*>",
            with: "\n",
            options: .regularExpression
        )
        work = work.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        work = decodeEntities(work)
        let lines = work
            .components(separatedBy: "\n")
            .map { line in
                line.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    static func decodeEntities(_ text: String) -> String {
        var output = text
        output = output.replacing(/&#(\d+);/) { match in
            guard let code = UInt32(match.1), let scalar = Unicode.Scalar(code) else {
                return String(match.0)
            }
            return String(Character(scalar))
        }
        output = output.replacing(/&#x([0-9a-fA-F]+);/) { match in
            guard let code = UInt32(match.1, radix: 16), let scalar = Unicode.Scalar(code) else {
                return String(match.0)
            }
            return String(Character(scalar))
        }
        // &amp; MUST stay last so a literal "&amp;mdash;" isn't double-decoded.
        let named: [(String, String)] = [
            ("&nbsp;", " "), ("&quot;", "\""), ("&lt;", "<"), ("&gt;", ">"), ("&apos;", "'"),
            ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"), ("&deg;", "°"),
            ("&trade;", "™"), ("&copy;", "©"), ("&reg;", "®"), ("&euro;", "€"),
            ("&pound;", "£"), ("&times;", "×"),
            ("&rsquo;", "'"), ("&lsquo;", "'"), ("&rdquo;", "\""), ("&ldquo;", "\""),
            ("&amp;", "&"),
        ]
        for (entity, character) in named {
            output = output.replacingOccurrences(of: entity, with: character)
        }
        return output
    }
}

public struct FetchPageTool: AgentTool {
    private static let log = Logger(subsystem: M1K3Log.subsystem, category: "fetch-page")

    public let name = "fetch_page"
    /// P1 same-turn exclusion (context-tools charter): this tool reaches the
    /// network, so it never runs in the same turn as a local-sensitive tool.
    public let exclusionClass: ToolExclusionClass? = .network
    public let description =
        "Read a web page's actual content — a URL or domain the user gave you, or a "
            + "web_search result you want in full. Argument: the page URL."
    public let parameters = [
        ToolParameter(name: "url", description: "the http(s) page URL"),
    ]

    private let fetcher: any HTTPFetching
    private let maxCharacters: Int

    public init(fetcher: any HTTPFetching = RetryingHTTPFetcher.production, maxCharacters: Int = 1500) {
        self.fetcher = fetcher
        self.maxCharacters = maxCharacters
    }

    public func execute(input: [String: String]) async throws -> ToolResult {
        let raw = (input["url"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = Self.validatedURL(raw) else {
            return ToolResult(output: "Error: fetch_page needs a full http(s) URL "
                + "(use one from the web_search results).")
        }

        do {
            let (data, response) = try await fetcher.fetch(Self.pageRequest(for: url))
            if HTTPStatus.classify(response.statusCode) != .ok {
                Self.log.notice("HTTP \(response.statusCode) for \(url.host() ?? "?", privacy: .public)")
                return ToolResult(output: "Error: the page returned HTTP \(response.statusCode) "
                    + "— try another result.")
            }
            let contentType = response.value(forHTTPHeaderField: "Content-Type")
            let html = BodyDecoder.decode(data, contentType: contentType)
            let text = HTMLTextExtractor.text(from: html)
            Self.log.info("""
            fetched \(url.host() ?? "?", privacy: .public): HTTP \(response.statusCode), \
            \(html.count) bytes → \(text.count) chars readable
            """)
            guard !text.isEmpty else {
                return ToolResult(output: "The page at \(url.host() ?? "that address") had "
                    + "no readable text (it may need JavaScript). Try another result.")
            }
            guard text.count > maxCharacters else {
                return ToolResult(output: text)
            }
            let capped = text.prefix(maxCharacters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ToolResult(output: capped + "…")
        } catch {
            Self.log.error("fetch failed for \(url.absoluteString, privacy: .public): \(error, privacy: .public)")
            return ToolResult(output: "Error: could not fetch the page — \(error.localizedDescription)")
        }
    }

    /// Scheme/host-guarded http(s) URL, or nil if not a fetchable page.
    static func validatedURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host() != nil,
              // fetch_page fires from the user's Mac and returns the body to the
              // model — a strong SSRF primitive. Refuse loopback / private /
              // metadata targets, the same gate open_link uses.
              !WebURLPolicy.isLocalOrPrivate(url)
        else { return nil }
        return url
    }

    /// The browser-headed request both fetch_page and the web_search auto-deepen
    /// chain use to read a page.
    static func pageRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(WebSearchTool.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("en-GB,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        return request
    }

    /// The core read shared with web_search's deterministic deepen: capped
    /// readable text, or nil when the page can't be read (bad URL, non-OK status,
    /// or a JS-only/empty body). Never throws — the caller degrades gracefully.
    /// Internal on purpose: the only caller is WebSearchTool's deepen in this
    /// module (110 review nit — no protocol witness forces `public`).
    func readablePage(at raw: String) async -> String? {
        guard let url = Self.validatedURL(raw) else { return nil }
        do {
            let (data, response) = try await fetcher.fetch(Self.pageRequest(for: url))
            guard HTTPStatus.classify(response.statusCode) == .ok else { return nil }
            let html = BodyDecoder.decode(
                data, contentType: response.value(forHTTPHeaderField: "Content-Type")
            )
            let text = HTMLTextExtractor.text(from: html)
            guard !text.isEmpty else { return nil }
            guard text.count > maxCharacters else { return text }
            return text.prefix(maxCharacters).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        } catch {
            return nil
        }
    }
}
