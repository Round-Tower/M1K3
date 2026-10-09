//
//  DocumentTools.swift
//  M1K3KnowledgeTools
//
//  Two more agent tools over the knowledge store, completing the MVP set
//  alongside SearchKnowledgeTool (the plan's search/list/get trio):
//   - ListDocumentsTool: enumerate what M1K3 knows.
//   - GetDocumentTool: pull a named document's full text.
//
//  Both back the same surface the MCP server will expose (P10). Thin wrappers
//  over KnowledgeStore.allItems / item / chunks.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-fable-5, 2026-07-02 — GetDocumentTool renders via
//  DocumentRenderer (shared with the MCP get_document): windowed paging with
//  a resume-offset footer replaces the silent 4,000-char ellipsis truncation.
//  Review: Kev + claude-fable-5.1, 2026-10-09 (#523 second-pass fold) — `excludedKinds` on both tools:
//  the MCP ask's palette builds them with KnowledgeKind.withheldFromMCP, so a Photo caption is never
//  listed, never title-matched, and its chunks never read (the leak the second pass found). Query-side
//  via `allItems(excluding:)`; the local default (empty) is byte-identical to before.

import Foundation
import M1K3Agent
import M1K3Knowledge

/// Lists stored items (documents, calls, notes), newest first.
public struct ListDocumentsTool: AgentTool {
    public let name = "list_documents"
    public let description =
        "List the documents, calls, and notes M1K3 has stored. No argument needed."
    public let parameters: [ToolParameter] = []

    private let store: KnowledgeStore
    private let limit: Int
    /// Kinds this palette never lists (the MCP ask passes `KnowledgeKind.withheldFromMCP`).
    private let excludedKinds: Set<KnowledgeKind>

    public init(store: KnowledgeStore, limit: Int = 50, excludedKinds: Set<KnowledgeKind> = []) {
        self.store = store
        self.limit = limit
        self.excludedKinds = excludedKinds
    }

    public func execute(input _: [String: String]) async throws -> ToolResult {
        let items = try store.allItems(excluding: excludedKinds, limit: limit)
        // Wording is load-bearing: ToolDispatch.emptyResultPrefixes reads it (ADR 0009).
        guard !items.isEmpty else { return ToolResult(output: "No stored knowledge yet.") }
        let body = items.enumerated().map { index, item in
            "\(index + 1). \(item.title) [\(item.kind.rawValue)]"
        }.joined(separator: "\n")
        return ToolResult(output: body)
    }
}

/// Fetches a stored item's full text by title (case-insensitive substring),
/// windowed with a resume-offset footer (DocumentRenderer — the same paging
/// the MCP get_document serves; was a silent 4,000-char ellipsis cut).
public struct GetDocumentTool: AgentTool {
    public let name = "get_document"
    public let description =
        "Get the full text of a stored document by title. Argument: the document title (or part of it); "
            + "optional offset to continue a long document from a previous call's footer."
    public let parameters = [
        ToolParameter(name: "title", description: "the document title to fetch"),
        ToolParameter(name: "offset", description: "character offset to resume from (optional)", isRequired: false),
    ]

    private let store: KnowledgeStore
    private let maxChars: Int
    /// Kinds this palette never fetches: an excluded item is not a title-match
    /// candidate, so its chunks are never read (the MCP ask passes
    /// `KnowledgeKind.withheldFromMCP`).
    private let excludedKinds: Set<KnowledgeKind>

    public init(store: KnowledgeStore, maxChars: Int = 4000, excludedKinds: Set<KnowledgeKind> = []) {
        self.store = store
        self.maxChars = maxChars
        self.excludedKinds = excludedKinds
    }

    public func execute(input: [String: String]) async throws -> ToolResult {
        let query = (input["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return ToolResult(output: "Error: empty title.") }

        let items = try store.allItems(excluding: excludedKinds, limit: 500)
        guard let match = items.first(where: { $0.title.range(of: query, options: .caseInsensitive) != nil }) else {
            return ToolResult(output: "No document matching \"\(query)\".")
        }
        let offset = Int(input["offset"] ?? "0") ?? 0
        let chunks = try store.chunks(forItem: match.id)
        return ToolResult(output: DocumentRenderer.render(
            title: match.title, kind: match.kind, chunks: chunks,
            maxChars: maxChars, offset: offset
        ))
    }
}
