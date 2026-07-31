//
//  GroundedSearch.swift
//  M1K3Knowledge
//
//  The one retrieval policy every search surface serves: with an embedder,
//  two-lane gated hybrid (documents + memories get separate top-K budgets,
//  GroundingGate floors both — ungated nearest-neighbour garbage was the
//  confabulation fuel); without one, FTS with the strict→relaxed retry.
//
//  Extracted from SearchKnowledgeTool so the MCP surface (which served
//  FTS-only even inside the app, where a live embedder sits in env) runs the
//  SAME policy as the agent tool. An empty result means "nothing cleared the
//  floor" — each caller phrases its own abstention.
//
//  Signed: Kev + claude-fable-5, 2026-07-02, Confidence 0.85 (policy lifted
//  verbatim from the agent tool's TDD'd branches; MCP-side hybrid is
//  test-pinned in KnowledgeMCPToolsTests, the in-app embedder wire is
//  verify-by-launch). Prior: Kev + claude-opus-4-8 (SearchKnowledgeTool).
//

import Foundation

/// Retrieval core shared by the agent tool and the MCP tools.
public enum GroundedSearch {
    /// Hybrid two-lane gated retrieval when `embedder` exists, FTS otherwise.
    /// Empty array ⇒ nothing cleared the relevance floor (abstain upstream).
    public static func run(
        store: KnowledgeStore,
        embedder: (any EmbeddingService)?,
        query: String,
        limit: Int
    ) async throws -> [ChunkHit] {
        guard let embedder else {
            return try store.searchFTS(query: query, limit: limit)
        }
        let queryVector = try await embedder.embedQuery(query)
        // Two-lane retrieval (documents + memories get SEPARATE top-K budgets),
        // the same path implicit grounding uses — so a large document corpus
        // can't crowd short memory facts out of one ranking BEFORE the floor.
        // Floors follow the embedder that produced the vectors: hashing's
        // cosine cone needs its own measured bars (EmbedderFloors).
        let (knowledge, memories) = try GroundingGate.partition(
            store.searchGrounding(
                query: query, queryVector: queryVector,
                documentLimit: limit, memoryLimit: limit
            ),
            floors: .forFingerprint(embedder.fingerprint)
        )
        return knowledge + memories
    }
}
