//
//  MemoryMCPTools.swift
//  M1K3MCPKit
//
//  The temporal-memory-graph tools for the in-app MCP server: recall_memory
//  (hybrid recall over atomic facts), related_memory (recall a seed, then walk
//  the graph one hop out), and memory_stats (watch the graph grow). They expose
//  the M1K3Memory store — SEPARATE from the RAG document corpus search_knowledge
//  reads — so a visiting agent (or Kev, by hand) can poke the memory graph the
//  same way the canary was live-proved.
//
//  Handlers are app-injected closures (the IntelligenceMCPTools / VoiceMCPTools
//  pattern): the embedder + the live MemoryStore live in the app's MainActor
//  glue; this package formats the typed results into text an LLM can read. The
//  package imports M1K3Memory only for the value types (Memory / MemoryHit) it
//  formats — never the embedder or the GRDB path.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-16, Confidence 0.85 (formatting +
//  empty-state contract test-pinned against a real in-memory store; live
//  embedder/path/dual-write wiring is app glue, verify-at-⌘R). Prior: Unknown.
//  Review: Kev + claude-opus-5-5, 2026-09-27 — #379: recall/related/forget queries read through
//  `MCPInput.text` (capped before the embedder, wrong type refused). Confidence 0.85.
//

import Foundation
import M1K3Memory
import MCP

/// Errors surfaced by the memory-graph tools. Distinct from `MCPVoiceError` so a
/// recall/related failure reads honestly in the logs (mirrors the per-domain
/// error pattern the voice tools use).
public struct MCPMemoryError: Error, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// A small summary for `memory_stats` — the "M1K3 remembers N things" number a
/// visiting agent (or Kev) can poll to watch the graph grow. Kept as a value
/// type so the app glue can fill it without leaking the store across the seam.
public struct MemoryStatsSummary: Sendable, Equatable {
    /// Live (non-superseded) memory count.
    public let liveCount: Int

    public init(liveCount: Int) {
        self.liveCount = liveCount
    }
}

/// The app-injected implementations behind the memory-graph tools. Each closure
/// embeds + queries the live MemoryStore on the app side; this package only
/// formats what comes back.
public struct MemoryToolHandlers: Sendable {
    /// Embed the query, recall matching facts (hybrid + cutoff). May be empty.
    public var recall: @Sendable (_ query: String) async throws -> [MemoryHit]
    /// Recall the top hit for the query, then return it plus its graph
    /// neighbours. `nil` when nothing clears the recall bar (no seed to anchor).
    public var related: @Sendable (_ query: String) async throws -> (seed: Memory, neighbours: [Memory])?
    /// A snapshot of the store for `memory_stats`.
    public var stats: @Sendable () async throws -> MemoryStatsSummary
    /// Forget the best-matching fact for the query — hard-delete from the graph
    /// AND the document corpus. Returns what happened (irreversible, so it's
    /// audited): forgotten, or kept because nothing was a confident match.
    public var forget: @Sendable (_ query: String) async throws -> ForgetOutcome

    public init(
        recall: @escaping @Sendable (_ query: String) async throws -> [MemoryHit],
        related: @escaping @Sendable (_ query: String) async throws -> (seed: Memory, neighbours: [Memory])?,
        stats: @escaping @Sendable () async throws -> MemoryStatsSummary,
        forget: @escaping @Sendable (_ query: String) async throws -> ForgetOutcome
    ) {
        self.recall = recall
        self.related = related
        self.stats = stats
        self.forget = forget
    }
}

public func makeMemoryToolDefinitions(handlers: MemoryToolHandlers) -> [MCPToolDefinition] {
    [
        MCPToolDefinition(
            tool: Tool(
                name: "recall_memory",
                description: "Recall atomic facts M1K3 remembers about the user — the temporal memory "
                    + "GRAPH, separate from the document corpus search_knowledge reads. Returns the "
                    + "matching facts (with a similarity hint) or says so honestly when nothing is "
                    + "recalled. Use it to check what M1K3 has stored about a person, preference, or decision.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "what to recall (a name, topic, or question)"],
                    ],
                    "required": ["query"],
                ]
            ),
            handler: { args in
                let query = try MCPInput.text(args, "query", tool: "recall_memory", maxLength: MCPInput.maxQuery) ?? ""
                guard !query.isEmpty else { throw MCPMemoryError("recall_memory requires a non-empty query") }
                let hits = try await handlers.recall(query)
                return formatRecall(hits, query: query)
            }
        ),
        MCPToolDefinition(
            tool: Tool(
                name: "related_memory",
                description: "Recall the single best matching fact for the query, then walk M1K3's "
                    + "memory GRAPH one step out to its neighbours (linked or superseded facts). Use it "
                    + "to see how a memory connects to others — not just flat recall. Says so when "
                    + "there is no matching fact to anchor from.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": ["type": "string", "description": "what to anchor the graph walk on"],
                    ],
                    "required": ["query"],
                ]
            ),
            handler: { args in
                let query = try MCPInput.text(args, "query", tool: "related_memory", maxLength: MCPInput.maxQuery) ?? ""
                guard !query.isEmpty else { throw MCPMemoryError("related_memory requires a non-empty query") }
                guard let result = try await handlers.related(query) else {
                    return "Nothing recalled for “\(query)” — no fact to anchor the graph walk on."
                }
                return formatRelated(seed: result.seed, neighbours: result.neighbours, query: query)
            }
        ),
        MCPToolDefinition(
            tool: Tool(
                name: "memory_stats",
                description: "How many atomic facts M1K3 currently remembers (the live, non-superseded "
                    + "count). Handy for watching the memory graph grow as facts are remembered.",
                inputSchema: ["type": "object", "properties": [:]]
            ),
            handler: { _ in
                let summary = try await handlers.stats()
                let noun = summary.liveCount == 1 ? "thing" : "things"
                return "M1K3 remembers \(summary.liveCount) \(noun)."
            }
        ),
        MCPToolDefinition(
            tool: Tool(
                name: "forget_memory",
                description: "Permanently forget a fact M1K3 remembers — the consent primitive, the "
                    + "counterpart to remember. Finds the single best-matching memory for the query and "
                    + "HARD-DELETES it from BOTH the memory graph AND the document corpus (no residue). "
                    + "Irreversible: when no memory is a confident match it deletes NOTHING and tells you "
                    + "the closest, so a vague query can't erase the wrong fact. Repeat the remembered "
                    + "FACT's text word-for-word (as recall_memory returned it) — not your search query.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "query": [
                            "type": "string",
                            "description": .string(
                                "the fact to forget — repeat the remembered fact's text "
                                    + "word-for-word (not your search query) for precision"
                            ),
                        ],
                    ],
                    "required": ["query"],
                ]
            ),
            handler: { args in
                let query = try MCPInput.text(args, "query", tool: "forget_memory", maxLength: MCPInput.maxQuery) ?? ""
                guard !query.isEmpty else { throw MCPMemoryError("forget_memory requires a non-empty query") }
                return try formatForget(await handlers.forget(query), query: query)
            }
        ),
    ]
}

// MARK: - Formatting

private func formatRecall(_ hits: [MemoryHit], query: String) -> String {
    guard !hits.isEmpty else {
        return "Nothing recalled for “\(query)”."
    }
    return hits.enumerated().map { index, hit in
        "\(index + 1). \(hit.memory.text)\(similarityHint(hit.similarity)) [\(hit.memory.kind.rawValue)]"
    }.joined(separator: "\n")
}

private func formatRelated(seed: Memory, neighbours: [Memory], query _: String) -> String {
    var out = "Anchor: \(seed.text) [\(seed.kind.rawValue)]"
    if neighbours.isEmpty {
        out += "\n\n(No connected memories yet.)"
    } else {
        out += "\n\nConnected memories:\n"
        out += neighbours.enumerated().map { index, memory in
            "\(index + 1). \(memory.text) [\(memory.kind.rawValue)]"
        }.joined(separator: "\n")
    }
    return out
}

private func formatForget(_ outcome: ForgetOutcome, query: String) -> String {
    switch outcome {
    case let .forgotten(text):
        return "Forgotten: “\(text)”. It's gone from M1K3's memory — graph and corpus, no residue."
    case let .notConfident(closest):
        guard let closest else {
            return "Nothing matching “\(query)” to forget."
        }
        return "Nothing confident enough to forget for “\(query)”. Closest: “\(closest)” — "
            + "if that's the one, repeat it back word-for-word to forget it."
    }
}

/// A coarse, non-numeric-noise similarity hint ("~83% match"). Omitted when the
/// hit carried no cosine score (FTS-only after the cutoff backfill — rare).
private func similarityHint(_ similarity: Float?) -> String {
    guard let similarity else { return "" }
    return " (~\(Int((similarity * 100).rounded()))% match)"
}
