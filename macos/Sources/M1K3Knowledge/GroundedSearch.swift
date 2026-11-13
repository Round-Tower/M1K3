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
//  Review: Kev + claude-fable-5.1, 2026-10-09 (fold) — `excludedKinds`, the per-call withhold (MCP keeps
//  Photo captions out).
//  Review: Kev + claude-opus-5.5, 2026-10-23 — #670: on the hashing arm, when no document clears the floor,
//  HashingKeywordLane admits one strict-AND BM25 chunk. Confidence 0.8 (pinned in HashingKeywordLaneTests).
//  Review: Kev + claude-fable-5.1, 2026-10-09 (#523 second-pass fold) — both lanes exclude in the query
//  (the FTS fallback post-filtered after `limit`, so crowding Photos could starve an MCP page).
//  Review: Kev + claude-fable-5.2, 2026-11-13 — `page`: one ranked list of at most `limit` for the MCP
//  search_knowledge, which returned up to 2 × limit (each lane took the whole budget) with every document
//  above every memory (found live through the Claude Code plugin: limit 3 gave 4, an unrelated paper's
//  figure caption above the memory titled like the query). `run` is unchanged for the agent tool and the
//  App Intent. Confidence 0.8: the order is pinned in GroundedSearchPageTests; margin-over-floor as the
//  cross-lane score is a heuristic with no blind set behind it yet. Challenged the same day: Gemma's and
//  Qwen's lanes have comparable margins; hashing's do not, so on hashing floors the lanes take turns.
//  Open: score `page`'s order on a held-out query set (KEYEVAL's fixtures would do) before the agent adopts it.
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
        limit: Int,
        excludedKinds: Set<KnowledgeKind> = []
    ) async throws -> [ChunkHit] {
        guard let embedder else {
            return try store.searchFTS(query: query, limit: limit, excluding: excludedKinds)
        }
        let gated = try await lanes(
            store: store, embedder: embedder, query: query, limit: limit, excludedKinds: excludedKinds
        )
        return gated.knowledge + gated.memories
    }

    /// One ranked page for a caller that asked for `limit` results (the MCP
    /// `search_knowledge`): the same gated lanes as `run`, merged by relevance
    /// and cut to `limit` in total. `run` hands back both lanes whole, each up
    /// to `limit`, documents first — right for the agent's two prompt blocks,
    /// wrong for a caller counting results.
    public static func page(
        store: KnowledgeStore,
        embedder: (any EmbeddingService)?,
        query: String,
        limit: Int,
        excludedKinds: Set<KnowledgeKind> = []
    ) async throws -> [ChunkHit] {
        guard let embedder else {
            return try store.searchFTS(query: query, limit: limit, excluding: excludedKinds)
        }
        let gated = try await lanes(
            store: store, embedder: embedder, query: query, limit: limit, excludedKinds: excludedKinds
        )
        return page(
            knowledge: gated.knowledge, memories: gated.memories, limit: limit,
            floors: .forFingerprint(embedder.fingerprint)
        )
    }

    /// Merge two gated lanes into one page of at most `limit` hits, best first.
    ///
    /// A hit's score is its MARGIN over its own kind's floor, never its raw
    /// cosine: short facts embed lower than document chunks (the reason the
    /// lanes are separate), so raw cosine would sink every memory. An unscored
    /// hit (the keyword stand-in) sorts last. Ties keep lane order, documents
    /// first. A lane that kept anything keeps one seat when there are two or
    /// more, so neither kind can crowd the other off the page entirely.
    static func page(
        knowledge: [ChunkHit], memories: [ChunkHit], limit: Int, floors: EmbedderFloors
    ) -> [ChunkHit] {
        let limit = KnowledgeStore.clampedSearchLimit(limit)
        guard limit > 0 else { return [] }
        // Hashing's lanes are not comparable by margin: its memory floor (0.10) sits far under
        // its own noise ceiling (0.408), so a stray memory out-margins the weakest TRUE chunk
        // (0.402 − 0.35). There the lanes take turns, best of each first.
        if floors == .hashing {
            var turns: [ChunkHit] = []
            for index in 0 ..< Swift.max(knowledge.count, memories.count) {
                if index < knowledge.count { turns.append(knowledge[index]) }
                if index < memories.count { turns.append(memories[index]) }
            }
            return Array(turns.prefix(limit))
        }
        func margin(_ hit: ChunkHit) -> Float {
            guard let similarity = hit.similarity else { return -.infinity }
            return similarity - (hit.kind == .memory ? floors.memory : floors.chunk)
        }
        // Sort indices, not hits: `sorted` is not stable, the index is the tie-break.
        let all = knowledge + memories
        let order = all.indices.sorted { lhs, rhs in
            let (left, right) = (margin(all[lhs]), margin(all[rhs]))
            return left == right ? lhs < rhs : left > right
        }
        var seats = Array(order.prefix(limit))
        if limit >= 2, seats.count == limit {
            let isMemory = { (index: Int) in index >= knowledge.count }
            for wantMemory in [false, true] where !seats.contains(where: { isMemory($0) == wantMemory }) {
                // `order` is best-first, so the first of the missing lane is its best.
                guard let best = order.first(where: { isMemory($0) == wantMemory }) else { continue }
                seats[seats.count - 1] = best
            }
        }
        return seats.map { all[$0] }
    }

    /// The gated two-lane retrieval behind `run` and `page`.
    private static func lanes(
        store: KnowledgeStore,
        embedder: any EmbeddingService,
        query: String,
        limit: Int,
        excludedKinds: Set<KnowledgeKind>
    ) async throws -> (knowledge: [ChunkHit], memories: [ChunkHit]) {
        let queryVector = try await embedder.embedQuery(query)
        // Two-lane retrieval (documents + memories get SEPARATE top-K budgets),
        // the same path implicit grounding uses — so a large document corpus
        // can't crowd short memory facts out of one ranking BEFORE the floor.
        // Floors follow the embedder that produced the vectors: hashing's
        // cosine cone needs its own measured bars (EmbedderFloors).
        let (knowledge, memories) = try GroundingGate.partition(
            store.searchGrounding(
                query: query, queryVector: queryVector,
                documentLimit: limit, memoryLimit: limit, excludedKinds: excludedKinds
            ),
            floors: .forFingerprint(embedder.fingerprint)
        )
        // #670: the hashing cone never reaches a whole-document chunk on a keyword
        // question; one strict-AND BM25 chunk stands in when the cosine lane kept none.
        if knowledge.isEmpty, let keyword = try? HashingKeywordLane.admit(
            store: store, query: query, fingerprint: embedder.fingerprint, excludedKinds: excludedKinds
        ) {
            return ([keyword], memories)
        }
        return (knowledge, memories)
    }
}
