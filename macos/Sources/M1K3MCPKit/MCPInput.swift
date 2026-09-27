//
//  MCPInput.swift
//  M1K3MCPKit
//
//  The free-text argument gate for the MCP tools (#378, #379). A wrong-typed argument
//  (`"query": 42`) used to read as empty; an uncapped one (a 130 KB query) held the shared
//  embedder for 43 s and came back echoed in full. Both are now refusals the registry turns
//  into `isError` — a throw is the one failure signal every MCP client (and the `m1k3` CLI's
//  exit code) reads. Blank or absent stays nil, so each tool keeps its own "requires …" line.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-27, Confidence 0.8 (the caps are judgement: well
//  past any real query, question, note or utterance, well short of a stall). Prior: none.
//

import Foundation
import MCP

/// A refused argument. Its description is the whole message the client sees.
public struct MCPInputError: Error, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

public enum MCPInput {
    /// A search or recall query. It is embedded, and the embedder is shared with the chat,
    /// the HUD and `ask_m1k3`; a query past this has stopped being one.
    public static let maxQuery = 1000
    /// An `ask_m1k3` question: room for pasted context, well inside Mini's window.
    public static let maxQuestion = 4000
    /// A `remember` title.
    public static let maxTitle = 200
    /// A `remember` note or a `speak` utterance (about twenty minutes of speech).
    public static let maxText = 20000
    /// How much of the caller's text a reply quotes back.
    public static let echoLength = 80

    /// The trimmed string argument `key`: nil when absent, null or blank. Throws when it is
    /// not a string, or runs past `maxLength` once trimmed; the refusal never quotes it.
    /// Counted in Unicode scalars, not characters: one base letter can carry any number of
    /// combining marks and still be ONE character, so a character cap let a megabyte through
    /// (#439 review). A scalar is still one character for any real text.
    public static func text(_ args: [String: Value]?, _ key: String, tool: String, maxLength: Int) throws -> String? {
        let text: String
        switch args?[key] {
        case nil, .null?:
            return nil
        case let .string(value)?:
            text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        default:
            throw MCPInputError("\(tool): \(key) must be a string")
        }
        guard !text.isEmpty else { return nil }
        let length = text.unicodeScalars.count
        guard length <= maxLength else {
            throw MCPInputError("\(tool): \(key) is over \(maxLength) characters (got \(length))")
        }
        return text
    }

    /// The caller's text as a reply quotes it: whole when short, else its start and "…".
    public static func echo(_ text: String) -> String {
        text.count <= echoLength ? text : String(text.prefix(echoLength - 1)) + "…"
    }
}
