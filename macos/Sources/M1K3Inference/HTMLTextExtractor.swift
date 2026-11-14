//
//  HTMLTextExtractor.swift
//  M1K3Inference
//
//  Pure HTML → readable text. Moved here unchanged from M1K3AgentTools/FetchPageTool.swift
//  (its history and reviews live in that file's header: the quote-aware tag, the possessive
//  one-pass strip, the byte cap) so the read route (`ReadSanitizer`: a file or a paste handed to
//  M1K3 to read) can clean markup without linking the agent tools.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-14 (the move only), Confidence 0.9: the code and its
//  tests moved verbatim; only the access level of four members changed.
//  Prior: FetchPageTool.swift (Kev + claude-fable-5, 2026-06-10, and its reviews through 2026-10-28)

import Foundation

/// Pure HTML → readable text: drop head/script/style/comments, turn block
/// boundaries into line breaks, strip tags, decode entities, tidy whitespace.
public enum HTMLTextExtractor {
    /// One tag: `<` then a letter, `/`, `!` or `?` (so "3 < 4" is text), up to the first `>` outside a
    /// quoted value. Wikipedia's data-mw JSON sits in single quotes and leaves `>` unescaped; `<[^>]+>`
    /// ended the tag there and the JSON read as the page (2026-10-27). A value is quoted only after `=`,
    /// tried first, so a stray apostrophe (`alt=Kev's`) is one character, and a quoted value stops at `<`,
    /// so a quote left open ends at the next tag rather than swallowing the page. The loop is possessive
    /// over runs: it never backtracks, so an unclosed tag at the end of a page costs one pass, not every
    /// way to split its quotes (the pre-push review's 40 attributes would have taken days), and a long
    /// unquoted value is one step, not one stack frame a character. Nothing in a tag may be `<`, so a
    /// tag that never closes ends at the next one: a megabyte of `<a ` with no `>` is one pass, not a
    /// rescan to the end from every `<` (#740's second review).
    static let tag = #"<[A-Za-z/!?](?:=\s*"[^"<]*"|=\s*'[^'<]*'|[^>"'=<]+|["'=])*+>"#

    /// The most HTML any page read looks at, in UTF-8 bytes. The text a model sees is the page's top (a
    /// few thousand characters), so a megabyte reaches it on any real page. Bytes, not Characters: one
    /// grapheme cluster can carry any number of combining marks, and the regex passes count UTF-16 units,
    /// which never outnumber the bytes. Applied inside `text(from:)` and `PageBrief`'s title and meta
    /// reads, so every road in (fetch_page, the search deepen, open_link, MCP's open_link) is capped.
    public static let maxHTMLBytes = 1_000_000

    public static func bounded(_ html: String) -> String {
        guard html.utf8.count > maxHTMLBytes else { return html }
        // Lossy on purpose: the cut can split a character, which decodes to U+FFFD at the very end.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: html.utf8.prefix(maxHTMLBytes), as: UTF8.self)
    }

    /// Elements dropped whole: an opener and its closer, both matched without regard to case. A `word`
    /// opener must end at a word boundary, so `<head` never takes `<header>` (or `<script` a `<scripts>`).
    struct DroppedPair {
        let open: String
        let close: String
        var word = true
    }

    static let droppedPairs: [DroppedPair] = [
        DroppedPair(open: "<script", close: "</script>"),
        DroppedPair(open: "<style", close: "</style>"),
        DroppedPair(open: "<head", close: "</head>"),
        // Page chrome eats the output cap before content starts (seen live).
        DroppedPair(open: "<nav", close: "</nav>"),
        DroppedPair(open: "<header", close: "</header>"),
        DroppedPair(open: "<footer", close: "</footer>"),
        DroppedPair(open: "<!--", close: "-->", word: false),
    ]

    public static func text(from html: String) -> String {
        var work = bounded(html)
        for pair in droppedPairs {
            work = droppingPairs(in: work, open: pair.open, close: pair.close, word: pair.word)
        }
        // Block boundaries → newlines; td/th too, so adjacent cells don't run together.
        work = work.replacingOccurrences(
            of: "(?i)</(p|div|h[1-6]|li|tr|td|th|section|article|ul|ol|table)>|<br[^<>]*>",
            with: "\n",
            options: .regularExpression
        )
        work = work.replacingOccurrences(of: tag, with: "", options: .regularExpression)
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

    /// Each opener through its closer becomes one space, in one pass. The lazy regex this replaces
    /// (`<script\\b.*?</script>`) rescanned to the end from every opener when the closer never came. Here
    /// an opener with no closer ends the pass: no later opener could close either, so the rest stays
    /// for the tag strip, exactly as the regex left it.
    static func droppingPairs(in text: String, open: String, close: String, word: Bool) -> String {
        let source = NSString(string: text)
        let output = NSMutableString()
        var cursor = 0
        var searchFrom = 0
        while searchFrom < source.length {
            let opener = source.range(
                of: open, options: .caseInsensitive,
                range: NSRange(location: searchFrom, length: source.length - searchFrom)
            )
            guard opener.location != NSNotFound else { break }
            let afterOpen = NSMaxRange(opener)
            if word, afterOpen < source.length, isWordUnit(source.character(at: afterOpen)) {
                searchFrom = afterOpen
                continue
            }
            let closer = source.range(
                of: close, options: .caseInsensitive,
                range: NSRange(location: afterOpen, length: source.length - afterOpen)
            )
            guard closer.location != NSNotFound else { break }
            output.append(source.substring(with: NSRange(location: cursor, length: opener.location - cursor)))
            output.append(" ")
            cursor = NSMaxRange(closer)
            searchFrom = cursor
        }
        output.append(source.substring(from: cursor))
        return output as String
    }

    /// `\\b`'s word side for one UTF-16 unit: a letter, digit or underscore.
    private static func isWordUnit(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
    }

    public static func decodeEntities(_ text: String) -> String {
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
