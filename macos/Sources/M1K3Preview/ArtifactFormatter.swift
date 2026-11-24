//
//  ArtifactFormatter.swift
//  M1K3Preview
//
//  Signed (this file's CSP placement only): Kev + claude-opus-5-5, 2026-11-23, Confidence 0.9 — `injectCSPMeta`
//  puts the sandbox CSP first in the document (after a leading doctype) instead of splicing it into a `<head>` the
//  page could hide, omit or precede. Measured in WKWebView on macOS 27 with an inline-script canary: leading, the
//  CSP blocked the script with no head, with a script before the head, and with a normal head; the old splice let a
//  script before the head run. The rest of the file predates this. Prior: Unknown.
//  Review: Kev + claude-opus-5-5, 2026-11-23 — the lead is now `ArtifactSandboxPolicy.sealHead` (the CSP, then DNS
//  prefetch off); the house sheet anchors after it. Confidence 0.85.
//  Review: Kev + claude-opus-5-5, 2026-11-24 (#902 second pass) — the page's own prefetch-control metas and
//  dns-prefetch / preconnect links are stripped (`stripPrefetchHints`): the switch is a toggle, so a page's "on"
//  would have undone ours. Confidence 0.8 (pure + tested; the root packet capture is still owed).
//

import Foundation

public enum ArtifactFormatter {
    public static func format(_ artifact: CodeArtifact) -> CodeArtifact {
        var result = artifact
        switch artifact.language {
        case .html:
            result.source = formatHTML(artifact.source)
        case .css, .js, .code:
            result.source = trimLines(artifact.source)
        case .markdown:
            // Keep `source` as the raw markdown (the Code tab shows it); render the
            // Preview HTML into `previewSource`.
            result.previewSource = formatMarkdown(artifact.source)
        }
        return result
    }

    // MARK: - Markdown

    /// Render markdown into a full, styled, CSP-sealed HTML document for the preview
    /// WebView. The body comes from `MarkdownToHTML`; the shell mirrors the HTML path
    /// (charset + CSP) plus a small readable stylesheet that follows the system theme.
    public static func formatMarkdown(_ source: String) -> String {
        let body = MarkdownToHTML.render(source)
        let document = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
          <meta charset="UTF-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          \(ArtifactHouseStyle.styleElement)
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
        return injectCSPMeta(document)
    }

    // (The bespoke markdown stylesheet retired 2026-07-16 — markdown previews
    // now ride ArtifactHouseStyle, one design language across every artifact.)

    // MARK: - HTML

    public static func formatHTML(_ source: String) -> String {
        var html = closeUnclosedTags(source)
        html = ensureHTMLStructure(html)
        html = normalizeIndentation(html)
        return html
    }

    public static func ensureHTMLStructure(_ source: String) -> String {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        let hasDoctype = lower.hasPrefix("<!doctype")
        let hasHTML = lower.contains("<html")
        let hasHead = lower.contains("<head")
        let hasBody = lower.contains("<body")

        let structured: String
        if hasDoctype && hasHTML {
            structured = trimmed
        } else if hasDoctype && !hasHTML {
            // Strips only the bare HTML5 doctype; legacy PUBLIC/SYSTEM doctypes are
            // left in place (browsers tolerate a non-leading doctype inside <html>).
            let body = trimmed.replacingOccurrences(
                of: "<!doctype html>", with: "", options: [.caseInsensitive]
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            structured = "<!DOCTYPE html>\n<html lang=\"en\">\n\(body)\n</html>"
        } else if hasHTML && !hasDoctype {
            structured = "<!DOCTYPE html>\n" + trimmed
        } else if hasHead && hasBody {
            structured = "<!DOCTYPE html>\n<html lang=\"en\">\n\(trimmed)\n</html>"
        } else if hasBody {
            structured = "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n  <meta charset=\"UTF-8\">\n</head>\n\(trimmed)\n</html>"
        } else {
            structured = """
            <!DOCTYPE html>
            <html lang="en">
            <head>
              <meta charset="UTF-8">
            </head>
            <body>
            \(trimmed)
            </body>
            </html>
            """
        }

        // Defense in depth: seal the WebSocket/fetch/XHR egress the WKContentRuleList
        // can't reach (see ArtifactSandboxPolicy). The artifact preview also disables
        // JavaScript, so this is belt-and-braces — but a CSP costs nothing and survives
        // even if the preview surface ever re-enables scripting.
        // Then the house sheet: injected at head-open, so it sits BEFORE any
        // author <style> already in the document — the model's own styling
        // always wins the cascade; the house look is the classless floor.
        return injectHouseStyle(injectCSPMeta(structured))
    }

    /// Insert the classless house sheet as an early child of `<head>` (after the
    /// CSP meta when present — metas aren't stylesheets, but keeping the seal
    /// first reads honestly). Idempotent via the marker attribute; a document
    /// with no `<head>` is returned unchanged (every synthesized path has one).
    static func injectHouseStyle(_ html: String) -> String {
        guard !html.contains(ArtifactHouseStyle.marker) else { return html }
        let anchor: String.Index? = {
            if let seal = html.range(of: ArtifactSandboxPolicy.sealHead) { return seal.upperBound }
            return headContentIndex(of: html)
        }()
        guard let anchor else { return html }
        var result = html
        result.insert(contentsOf: "\n  " + ArtifactHouseStyle.styleElement, at: anchor)
        return result
    }

    /// The index just inside a TRUE `<head>` open tag, or nil when the document
    /// has none. Boundary-checked: "<head" must be followed by `>` or
    /// whitespace — `<header>` (a body element) must NOT match, or the CSP
    /// meta lands in body content where WebKit silently ignores it (review
    /// catch on #44; the bug predated the house sheet in `injectCSPMeta`).
    static func headContentIndex(of html: String) -> String.Index? {
        var search = html.startIndex ..< html.endIndex
        while let open = html.range(of: "<head", options: [.caseInsensitive], range: search) {
            if open.upperBound < html.endIndex {
                let next = html[open.upperBound]
                if next == ">" || next.isWhitespace,
                   let tagClose = html.range(of: ">", range: open.upperBound ..< html.endIndex)
                {
                    return tagClose.upperBound
                }
            }
            search = open.upperBound ..< html.endIndex
        }
        return nil
    }

    /// Put the sandbox CSP first in the document, after a leading doctype only. The HTML parser files a `<meta>`
    /// met before `<html>`/`<head>` into an implied `<head>`, so the policy is in force before any byte the page
    /// wrote: no `<head>`, a `<head>` inside a comment, a script before the head, or the policy's own text in the
    /// body can no longer skip or delay it (challenger, 2026-11-23). A policy the page adds can only tighten ours
    /// (policies intersect). Idempotent: a document already led by our tag comes back unchanged.
    static func injectCSPMeta(_ html: String) -> String {
        let (doctype, rest) = splitLeadingDoctype(html)
        guard !rest.hasPrefix(ArtifactSandboxPolicy.sealHead) else { return html }
        return doctype + ArtifactSandboxPolicy.sealHead + "\n" + stripPrefetchHints(String(rest))
    }

    /// The page's own DNS-prefetch levers, removed: a `x-dns-prefetch-control` meta (a toggle, not a policy: the
    /// page's "on" would undo our "off", #902 second pass) and `<link rel=dns-prefetch|preconnect>`, which resolve a
    /// name the page chose. Each match ends at the tag's first `>`, so a scan never runs past one tag.
    static func stripPrefetchHints(_ html: String) -> String {
        var result = html
        for pattern in prefetchHintPatterns {
            result = pattern.stringByReplacingMatches(
                in: result, range: NSRange(result.startIndex..., in: result), withTemplate: ""
            )
        }
        return result
    }

    private static let prefetchHintPatterns: [NSRegularExpression] = [
        #"<meta\b[^>]*\bhttp-equiv\s*=\s*["']?\s*x-dns-prefetch-control[^>]*>"#,
        #"<link\b[^>]*\brel\s*=\s*(?:"[^"]*\b(?:dns-prefetch|preconnect)\b[^"]*"|'[^']*\b(?:dns-prefetch|preconnect)\b[^']*'|(?:dns-prefetch|preconnect)\b)[^>]*>"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) } // swiftlint:disable:this force_try

    /// A leading `<!doctype …>` (kept first so the page stays in standards mode) and everything after it, with the
    /// whitespace between dropped. No doctype: an empty first half.
    static func splitLeadingDoctype(_ html: String) -> (doctype: String, rest: Substring) {
        let start = Substring(html).drop { $0.isWhitespace }
        guard start.lowercased().hasPrefix("<!doctype"), let close = start.firstIndex(of: ">") else {
            return ("", start)
        }
        let doctype = String(start[...close])
        return (doctype + "\n", start[start.index(after: close)...].drop { $0.isWhitespace })
    }

    // MARK: - Unclosed tags

    private static let voidElements: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    ]

    /// Best-effort for small-model output; does not handle `<` inside attribute values or raw-text elements.
    public static func closeUnclosedTags(_ source: String) -> String {
        var stack: [String] = []
        var scanner = source[source.startIndex...]

        while let openBracket = scanner.firstIndex(of: "<") {
            let afterBracket = source.index(after: openBracket)
            guard afterBracket < source.endIndex else { break }

            if source[afterBracket] == "/" {
                if let closeBracket = source[afterBracket...].firstIndex(of: ">") {
                    let tagNameStart = source.index(after: afterBracket)
                    let tagContent = source[tagNameStart ..< closeBracket]
                    let tagName = extractTagName(String(tagContent))
                    if let idx = stack.lastIndex(of: tagName) {
                        stack.remove(at: idx)
                    }
                    scanner = source[source.index(after: closeBracket)...]
                } else {
                    break
                }
            } else if source[afterBracket] == "!" || source[afterBracket] == "?" {
                if let closeBracket = source[afterBracket...].firstIndex(of: ">") {
                    scanner = source[source.index(after: closeBracket)...]
                } else {
                    break
                }
            } else {
                if let closeBracket = source[openBracket...].firstIndex(of: ">") {
                    let tagContent = source[afterBracket ..< closeBracket]
                    let contentStr = String(tagContent)

                    if contentStr.hasSuffix("/") {
                        scanner = source[source.index(after: closeBracket)...]
                        continue
                    }

                    let tagName = extractTagName(contentStr).lowercased()
                    if !tagName.isEmpty && !voidElements.contains(tagName) {
                        stack.append(tagName)
                    }
                    scanner = source[source.index(after: closeBracket)...]
                } else {
                    break
                }
            }
        }

        if stack.isEmpty { return source }

        var result = source
        for tag in stack.reversed() {
            result += "</\(tag)>"
        }
        return result
    }

    private static func extractTagName(_ content: String) -> String {
        let trimmed = content.trimmingCharacters(in: .whitespaces)
        let end = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "/" }) ?? trimmed.endIndex
        return String(trimmed[trimmed.startIndex ..< end]).lowercased()
    }

    // MARK: - Indentation

    public static func normalizeIndentation(_ source: String) -> String {
        let tokens = tokenize(source)
        var result = ""
        var depth = 0

        for token in tokens {
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            let isClose = trimmed.hasPrefix("</")
            let isOpen = trimmed.hasPrefix("<") && !isClose && !trimmed.hasPrefix("<!") && !trimmed.hasPrefix("<?")
            let tagName = isOpen || isClose ? extractTagName(String(trimmed.dropFirst(isClose ? 2 : 1))) : ""
            let isVoid = voidElements.contains(tagName)
            let isSelfClosing = trimmed.hasSuffix("/>")

            if isClose {
                depth = max(0, depth - 1)
            }

            let indent = String(repeating: "  ", count: depth)
            if !result.isEmpty { result += "\n" }
            result += indent + trimmed

            if isOpen && !isVoid && !isSelfClosing {
                let hasInlineClose = trimmed.contains("</\(tagName)>")
                if !hasInlineClose {
                    depth += 1
                }
            }
        }

        return result
    }

    /// Does not handle `<` inside <script>/<style> content; a raw-text element parser is the long-term fix.
    private static func tokenize(_ source: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inTag = false

        for char in source {
            if char == "<" {
                let text = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    tokens.append(text)
                }
                current = "<"
                inTag = true
            } else if char == ">", inTag {
                current += ">"
                tokens.append(current)
                current = ""
                inTag = false
            } else {
                current += String(char)
            }
        }

        let remaining = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remaining.isEmpty {
            tokens.append(remaining)
        }

        return tokens
    }

    // MARK: - CSS / JS

    private static func trimLines(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .init(charactersIn: " ")) == "" ? "" : String($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
