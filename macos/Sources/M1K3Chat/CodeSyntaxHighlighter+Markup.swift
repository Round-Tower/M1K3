//
//  CodeSyntaxHighlighter+Markup.swift
//  M1K3Chat
//
//  HTML and CSS rules for CodeSyntaxHighlighter. They get their own scanners
//  because neither fits the shared "comment / string / identifier" pass: HTML
//  has tags with attributes (and CSS/JS bodies inside <style>/<script>), CSS
//  has properties that look like identifiers but only count before a `:` in a
//  declaration block. Same contract as the rest: token texts joined reproduce
//  the input exactly, and unterminated input never crashes.
//
//  Signed: Kev + claude-opus-5-5, 2026-11-23, Confidence 0.8, Prior: Unknown (new file)

import Foundation

extension CodeSyntaxHighlighter {
    /// The markup languages routed to the dedicated scanners.
    enum MarkupLanguage {
        case html, css

        init?(_ language: String?) {
            switch language?.lowercased() {
            case "html", "htm", "xhtml", "xml", "svg": self = .html
            case "css", "scss": self = .css
            default: return nil
            }
        }
    }

    private struct Builder {
        var tokens: [CodeToken] = []

        mutating func append(_ kind: CodeTokenKind, _ text: String) {
            guard !text.isEmpty else { return }
            if let last = tokens.last, last.kind == kind {
                tokens[tokens.count - 1] = CodeToken(kind: kind, text: last.text + text)
            } else {
                tokens.append(CodeToken(kind: kind, text: text))
            }
        }

        /// An embedded language's tokens, kept apart from the tag that opened them
        /// (the first token never merges into the previous one).
        mutating func append(contentsOf more: [CodeToken]) {
            guard let first = more.first else { return }
            tokens.append(first)
            for token in more.dropFirst() {
                append(token.kind, token.text)
            }
        }
    }

    private static func has(_ needle: String, in chars: [Character], at index: Int, ignoringCase: Bool = false) -> Bool {
        let needleChars = Array(needle)
        guard index >= 0, index + needleChars.count <= chars.count else { return false }
        for (offset, character) in needleChars.enumerated() {
            let actual = chars[index + offset]
            if ignoringCase ? actual.lowercased() != character.lowercased() : actual != character {
                return false
            }
        }
        return true
    }

    private static func isNameCharacter(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "-" || c == "_" || c == ":" || c == "."
    }

    // MARK: HTML

    static func tokenizeHTML(_ code: String) -> [CodeToken] {
        var out = Builder()
        let chars = Array(code)
        let n = chars.count
        var i = 0

        while i < n {
            let c = chars[i]
            if has("<!--", in: chars, at: i) {
                var j = i + 4
                while j < n, !has("-->", in: chars, at: j) {
                    j += 1
                }
                j = min(j + 3, n)
                out.append(.comment, String(chars[i ..< j]))
                i = j
                continue
            }
            guard c == "<", i + 1 < n, chars[i + 1].isLetter || chars[i + 1] == "/" || chars[i + 1] == "!" else {
                out.append(.plain, String(c))
                i += 1
                continue
            }
            // A tag: `<`, optional `/` or `!`, the name.
            var j = i + 1
            if chars[j] == "/" || chars[j] == "!" { j += 1 }
            let nameStart = j
            while j < n, isNameCharacter(chars[j]) {
                j += 1
            }
            let name = String(chars[nameStart ..< j]).lowercased()
            let isClosing = chars[i + 1] == "/"
            out.append(.keyword, String(chars[i ..< j]))
            // Attributes, up to the tag's `>`.
            while j < n, chars[j] != ">" {
                let a = chars[j]
                if a == "\"" || a == "'" {
                    var k = j + 1
                    while k < n, chars[k] != a {
                        k += 1
                    }
                    k = min(k + 1, n)
                    out.append(.string, String(chars[j ..< k]))
                    j = k
                } else if a.isLetter || a == "_" || a == "@" || a == ":" {
                    var k = j
                    while k < n, isNameCharacter(chars[k]) || chars[k] == "@" {
                        k += 1
                    }
                    out.append(.type, String(chars[j ..< k]))
                    j = k
                } else if a == "/" {
                    out.append(.keyword, "/")
                    j += 1
                } else {
                    out.append(.plain, String(a))
                    j += 1
                }
            }
            if j < n {
                out.append(.keyword, ">")
                j += 1
            }
            i = j
            // <style> / <script> bodies read as CSS / JavaScript until their close tag.
            if !isClosing, name == "style" || name == "script", j <= n {
                var k = j
                while k < n, !has("</\(name)", in: chars, at: k, ignoringCase: true) {
                    k += 1
                }
                let body = String(chars[j ..< k])
                let inner = name == "style"
                    ? tokenizeCSS(body)
                    : tokenize(body, language: "javascript")
                out.append(contentsOf: inner)
                i = k
            }
        }
        return out.tokens
    }

    // MARK: CSS

    static func tokenizeCSS(_ code: String) -> [CodeToken] {
        var out = Builder()
        let chars = Array(code)
        let n = chars.count
        var i = 0
        var depth = 0

        /// A `:` after an identifier in a block is a declaration only when a `;` or `}` (not a `{`) comes next.
        func isDeclaration(colonAt colon: Int) -> Bool {
            var k = colon + 1
            while k < n {
                switch chars[k] {
                case "{": return false
                case ";", "}": return true
                default: k += 1
                }
            }
            return true
        }

        while i < n {
            let c = chars[i]
            if has("/*", in: chars, at: i) {
                var j = i + 2
                while j < n, !has("*/", in: chars, at: j) {
                    j += 1
                }
                j = min(j + 2, n)
                out.append(.comment, String(chars[i ..< j]))
                i = j
            } else if c == "\"" || c == "'" {
                var j = i + 1
                while j < n, chars[j] != c {
                    j += chars[j] == "\\" && j + 1 < n ? 2 : 1
                }
                j = min(j + 1, n)
                out.append(.string, String(chars[i ..< j]))
                i = j
            } else if c == "{" {
                depth += 1
                out.append(.plain, "{")
                i += 1
            } else if c == "}" {
                depth = max(0, depth - 1)
                out.append(.plain, "}")
                i += 1
            } else if c == "@", i + 1 < n, chars[i + 1].isLetter {
                var j = i + 1
                while j < n, chars[j].isLetter || chars[j] == "-" {
                    j += 1
                }
                out.append(.keyword, String(chars[i ..< j]))
                i = j
            } else if c == "!", has("!important", in: chars, at: i) {
                out.append(.keyword, "!important")
                i += 10
            } else if c == "#", depth > 0, i + 1 < n, chars[i + 1].isHexDigit {
                var j = i + 1
                while j < n, chars[j].isHexDigit {
                    j += 1
                }
                out.append(.number, String(chars[i ..< j]))
                i = j
            } else if c.isNumber || ((c == "." || c == "-") && i + 1 < n && chars[i + 1].isNumber && depth > 0) {
                var j = i + 1
                while j < n, chars[j].isNumber || chars[j] == "." {
                    j += 1
                }
                while j < n, chars[j].isLetter || chars[j] == "%" {
                    j += 1
                }
                out.append(.number, String(chars[i ..< j]))
                i = j
            } else if c.isLetter || c == "_" || c == "-" {
                var j = i
                while j < n, chars[j].isLetter || chars[j].isNumber || chars[j] == "-" || chars[j] == "_" {
                    j += 1
                }
                var k = j
                while k < n, chars[k] == " " || chars[k] == "\t" {
                    k += 1
                }
                let isProperty = depth > 0 && k < n && chars[k] == ":" && isDeclaration(colonAt: k)
                out.append(isProperty ? .keyword : .plain, String(chars[i ..< j]))
                i = j
            } else {
                out.append(.plain, String(c))
                i += 1
            }
        }
        return out.tokens
    }
}
