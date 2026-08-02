//
//  CodeSyntaxHighlighter.swift
//  M1K3Chat
//
//  A small, local, dependency-free tokenizer for the languages M1K3's own
//  code actually ships in (Swift, Kotlin, Python, JS/TS, JSON, Bash) plus a
//  generic C-family fallback — not a general-purpose highlighter. Pure token
//  kinds only (no Color/Font): this target stays SwiftUI-free, so the app
//  layer maps kinds to colors against whichever theme/ReadingMode is active.
//  An unrecognized or nil language returns the whole code as one `.plain`
//  token — never a crash, never a guess at a language M1K3 doesn't know.
//
//  Signed: Kev + claude-sonnet-5, 2026-07-22, Confidence 0.8, Prior: Unknown

import Foundation

public enum CodeTokenKind: Equatable, Sendable {
    case keyword, string, comment, number, type, plain
}

public struct CodeToken: Equatable, Sendable {
    public let kind: CodeTokenKind
    public let text: String
}

public enum CodeSyntaxHighlighter {
    /// Tokenize `code` for `language` (a fence info string, e.g. "swift",
    /// "py", "ts"; case-insensitive, aliases resolved). `nil`/unrecognized
    /// language → one `.plain` token holding the whole string unchanged.
    public static func tokenize(_ code: String, language: String?) -> [CodeToken] {
        guard let rules = rules(for: language) else {
            return code.isEmpty ? [] : [CodeToken(kind: .plain, text: code)]
        }
        return scan(code, rules: rules)
    }

    private struct LanguageRules {
        var lineComment: String?
        var blockComment: (open: String, close: String)?
        var stringQuotes: Set<Character> = ["\"", "'"]
        var tripleQuotes: [String] = []
        var keywords: Set<String> = []
        /// A bare identifier starting with an uppercase letter reads as a
        /// type name (String, URLSession…) — true for Swift/Kotlin/C-family/
        /// JS-TS, but not idiomatic enough in Python/Bash/JSON to bother.
        var detectsTypes = true
    }

    private static func normalize(_ language: String) -> String {
        switch language.lowercased() {
        case "swift": return "swift"
        case "kt", "kotlin": return "kotlin"
        case "py", "python", "python3": return "python"
        case "js", "javascript", "jsx", "mjs", "cjs", "ts", "typescript", "tsx": return "javascript"
        case "json", "jsonc": return "json"
        case "sh", "bash", "zsh", "shell", "console": return "bash"
        case "c", "cpp", "c++", "objc", "objective-c", "java", "csharp", "c#", "go", "rust", "php":
            return "clike"
        default: return language.lowercased()
        }
    }

    private static func rules(for language: String?) -> LanguageRules? {
        guard let language, !language.isEmpty else { return nil }
        switch normalize(language) {
        case "swift":
            return LanguageRules(
                lineComment: "//", blockComment: ("/*", "*/"),
                stringQuotes: ["\"", "'"], tripleQuotes: ["\"\"\""], keywords: swiftKeywords
            )
        case "kotlin":
            return LanguageRules(
                lineComment: "//", blockComment: ("/*", "*/"),
                stringQuotes: ["\"", "'"], tripleQuotes: ["\"\"\""], keywords: kotlinKeywords
            )
        case "python":
            return LanguageRules(
                lineComment: "#", blockComment: nil,
                stringQuotes: ["\"", "'"], tripleQuotes: ["\"\"\"", "'''"],
                keywords: pythonKeywords, detectsTypes: false
            )
        case "javascript":
            return LanguageRules(
                lineComment: "//", blockComment: ("/*", "*/"),
                stringQuotes: ["\"", "'", "`"], keywords: jsKeywords
            )
        case "json":
            return LanguageRules(
                stringQuotes: ["\""], keywords: ["true", "false", "null"], detectsTypes: false
            )
        case "bash":
            return LanguageRules(
                lineComment: "#", stringQuotes: ["\"", "'"], keywords: bashKeywords, detectsTypes: false
            )
        case "clike":
            return LanguageRules(
                lineComment: "//", blockComment: ("/*", "*/"),
                stringQuotes: ["\"", "'"], keywords: clikeKeywords
            )
        default:
            return nil
        }
    }

    /// A single left-to-right pass: at each position, try comment → triple-
    /// quoted string → quoted string → identifier/keyword/type → number,
    /// falling back to one plain character. Adjacent same-kind tokens merge
    /// (so a run of plain punctuation/whitespace stays one token).
    private static func scan(_ code: String, rules: LanguageRules) -> [CodeToken] {
        var tokens: [CodeToken] = []
        let chars = Array(code)
        var i = 0
        let n = chars.count

        func append(_ kind: CodeTokenKind, _ text: String) {
            guard !text.isEmpty else { return }
            if let last = tokens.last, last.kind == kind {
                tokens[tokens.count - 1] = CodeToken(kind: kind, text: last.text + text)
            } else {
                tokens.append(CodeToken(kind: kind, text: text))
            }
        }

        func matches(_ needle: String, at index: Int) -> Bool {
            let needleChars = Array(needle)
            guard index + needleChars.count <= n else { return false }
            for (offset, character) in needleChars.enumerated() where chars[index + offset] != character {
                return false
            }
            return true
        }

        while i < n {
            let c = chars[i]

            if let lineComment = rules.lineComment, matches(lineComment, at: i) {
                var j = i
                while j < n, chars[j] != "\n" {
                    j += 1
                }
                append(.comment, String(chars[i ..< j]))
                i = j
                continue
            }
            if let block = rules.blockComment, matches(block.open, at: i) {
                var j = i + block.open.count
                while j < n, !matches(block.close, at: j) {
                    j += 1
                }
                j = min(j + block.close.count, n)
                append(.comment, String(chars[i ..< j]))
                i = j
                continue
            }
            if let triple = rules.tripleQuotes.first(where: { matches($0, at: i) }) {
                var j = i + triple.count
                while j < n, !matches(triple, at: j) {
                    j += 1
                }
                j = min(j + triple.count, n)
                append(.string, String(chars[i ..< j]))
                i = j
                continue
            }
            if rules.stringQuotes.contains(c) {
                var j = i + 1
                while j < n, chars[j] != c {
                    if chars[j] == "\\", j + 1 < n { j += 2 } else { j += 1 }
                }
                j = min(j + 1, n)
                append(.string, String(chars[i ..< j]))
                i = j
                continue
            }
            if c.isLetter || c == "_" {
                var j = i
                while j < n, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" {
                    j += 1
                }
                let word = String(chars[i ..< j])
                if rules.keywords.contains(word) {
                    append(.keyword, word)
                } else if rules.detectsTypes, let first = word.first, first.isUppercase {
                    append(.type, word)
                } else {
                    append(.plain, word)
                }
                i = j
                continue
            }
            if c.isNumber {
                var j = i
                while j < n, chars[j].isNumber || chars[j] == "." || chars[j] == "_" || chars[j].isHexDigit {
                    j += 1
                }
                append(.number, String(chars[i ..< j]))
                i = j
                continue
            }
            append(.plain, String(c))
            i += 1
        }
        return tokens
    }

    private static let swiftKeywords: Set<String> = [
        "func", "var", "let", "if", "else", "guard", "return", "struct", "class", "enum",
        "protocol", "extension", "import", "for", "while", "switch", "case", "default",
        "break", "continue", "in", "try", "catch", "throw", "throws", "async", "await",
        "private", "public", "internal", "fileprivate", "static", "final", "override",
        "init", "deinit", "self", "Self", "nil", "true", "false", "where", "is", "as",
        "some", "any", "typealias", "associatedtype", "inout", "mutating", "lazy", "weak",
        "unowned", "defer", "repeat", "subscript", "willSet", "didSet", "get", "set",
    ]
    private static let kotlinKeywords: Set<String> = [
        "fun", "val", "var", "if", "else", "when", "for", "while", "do", "class", "object",
        "interface", "override", "private", "public", "internal", "protected", "companion",
        "data", "sealed", "enum", "is", "as", "in", "null", "true", "false", "return",
        "import", "package", "suspend", "try", "catch", "finally", "throw", "init", "this",
        "super", "typealias", "vararg", "inline", "reified", "lateinit", "const",
    ]
    private static let pythonKeywords: Set<String> = [
        "def", "class", "if", "elif", "else", "for", "while", "try", "except", "finally",
        "with", "as", "import", "from", "return", "yield", "lambda", "pass", "break",
        "continue", "in", "is", "not", "and", "or", "None", "True", "False", "self",
        "global", "nonlocal", "assert", "raise", "del", "async", "await",
    ]
    private static let jsKeywords: Set<String> = [
        "function", "var", "let", "const", "if", "else", "for", "while", "do", "switch",
        "case", "default", "break", "continue", "return", "try", "catch", "finally",
        "throw", "class", "extends", "super", "new", "this", "typeof", "instanceof", "in",
        "of", "import", "export", "from", "as", "async", "await", "yield", "null",
        "undefined", "true", "false", "void", "delete", "static", "get", "set",
        "interface", "type", "enum", "implements", "public", "private", "protected",
        "readonly", "namespace", "declare", "abstract",
    ]
    private static let bashKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac",
        "function", "return", "local", "export", "echo", "in", "until", "select", "break",
        "continue", "exit", "source", "alias", "unset", "readonly", "declare", "shift", "test",
    ]
    private static let clikeKeywords: Set<String> = [
        "if", "else", "for", "while", "do", "switch", "case", "default", "break",
        "continue", "return", "class", "struct", "void", "int", "float", "double", "char",
        "bool", "const", "static", "public", "private", "protected", "new", "this", "super",
        "import", "package", "namespace", "using", "typedef", "enum", "interface", "extends",
        "implements", "throw", "try", "catch", "finally", "func", "fn", "let", "mut",
    ]
}
