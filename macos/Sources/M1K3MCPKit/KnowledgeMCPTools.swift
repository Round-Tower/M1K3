//
//  KnowledgeMCPTools.swift
//  M1K3MCP
//
//  The substance behind the MCP server: query the KnowledgeStore and format the
//  results as text an LLM can read. Pure of the MCP transport (no swift-sdk
//  import) so it's testable against an in-memory store — the stdio wiring in
//  main.swift just calls these and wraps the strings in MCP content.
//
//  Search runs GroundedSearch: hybrid two-lane gated retrieval when the host
//  injects an embedder (the in-app HTTP server — the app has one live in env),
//  FTS-only when it can't (the stdio binary is a plain CLI with no embedder,
//  and MLX won't load outside an .app bundle anyway).
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.8, Prior: Unknown
//  Review: Kev + claude-fable-5, 2026-07-02 — search delegates to
//  GroundedSearch (the agent tool's two-lane gated policy; was FTS-only even
//  in-app) behind an optional embedder, stdio surface byte-identical via the
//  nil default; get_document rendering lifted to DocumentRenderer (shared
//  with the agent's GetDocumentTool).
//  Review: Kev + claude-opus-5-5, 2026-09-27 — #378/#379: an empty query, a bad id and an
//  unknown id throw (the registry's isError) instead of returning "Error: …" as success; a
//  no-results line quotes only the query's start (`MCPInput.echo`). A quarantined id still
//  refuses exactly as an absent one does. Confidence 0.85.
//  Review: Kev + claude-fable-5.1, 2026-10-09 — caption memory: `.image` (Photo) items are
//  withheld from list, search and get-by-id (KnowledgeKind.withheldFromMCP). Search over-reads
//  nothing: a Photo hit just drops from the ranked list. Fold: list excludes in the query
//  (`allItems(excluding:)`), so a page is never eaten by newer Photos.
//

import Foundation
import M1K3Knowledge

struct KnowledgeMCPTools {
    let store: KnowledgeStore
    var embedder: (any EmbeddingService)?

    init(store: KnowledgeStore, embedder: (any EmbeddingService)? = nil) {
        self.store = store
        self.embedder = embedder
    }

    /// Search stored knowledge (hybrid when an embedder is injected, FTS
    /// otherwise). Returns ranked chunks as text.
    func searchKnowledge(query: String, limit: Int = 5) async throws -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MCPInputError("search_knowledge requires a non-empty query") }
        // Photo captions describe private images: withheld from MCP clients.
        let hits = try await GroundedSearch.run(
            store: store, embedder: embedder, query: trimmed, limit: limit
        ).filter { !KnowledgeKind.withheldFromMCP.contains($0.kind) }
        guard !hits.isEmpty else {
            if embedder != nil {
                // Gated-empty: nothing cleared the relevance floor — abstain
                // honestly rather than hand the caller top-K garbage.
                return "Nothing relevant in stored knowledge for “\(MCPInput.echo(trimmed))” — "
                    + "the stored documents don't cover this."
            }
            return "No results for “\(MCPInput.echo(trimmed))”."
        }
        return hits.enumerated().map { index, hit -> String in
            let heading: String = hit.heading.map { " §\($0)" } ?? ""
            return "\(index + 1). [\(hit.itemTitle)\(heading)] (\(hit.kind.rawValue))\n\(hit.content)"
        }.joined(separator: "\n\n")
    }

    /// List indexed items (documents, calls, notes) with their ids.
    func listDocuments(limit: Int = 100) throws -> String {
        let items = try store.allItems(excluding: KnowledgeKind.withheldFromMCP, limit: limit)
        guard !items.isEmpty else { return "No documents indexed yet." }
        return items.map { item in
            "\(item.id.uuidString)  [\(item.kind.rawValue)]  \(item.title)"
        }.joined(separator: "\n")
    }

    /// Default character window per `get_document` call (DocumentRenderer owns
    /// the policy; this alias keeps the MCP surface's knob where it was).
    static let defaultMaxChars = DocumentRenderer.defaultMaxChars

    /// Full text of one item by id, chunk by chunk, windowed with a
    /// resume-offset footer (DocumentRenderer owns the rendering).
    func getDocument(idString: String, maxChars: Int = defaultMaxChars, offset: Int = 0) throws -> String {
        guard let id = UUID(uuidString: idString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw MCPInputError("“\(MCPInput.echo(idString))” is not a valid document id.")
        }
        guard let item = try store.item(id: id), item.kind != .quarantined,
              !KnowledgeKind.withheldFromMCP.contains(item.kind)
        else {
            // A quarantined item renders as absent, not as denied — the by-id
            // path must not confirm existence of what list/search never show
            // (index segregation; see KnowledgeKind.quarantined).
            throw MCPInputError("No document found with id \(id.uuidString).")
        }
        return try DocumentRenderer.render(
            title: item.title,
            kind: item.kind,
            chunks: store.chunks(forItem: id),
            maxChars: maxChars,
            offset: offset
        )
    }
}
