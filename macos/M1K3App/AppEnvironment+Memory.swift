//
//  AppEnvironment+Memory.swift
//  M1K3App
//
//  Thin accessors that turn the flat Memories list into an explorable graph
//  surface. Every method is a best-effort wrapper over the TESTED MemoryStore
//  graph APIs (allMemories / related / recall / forget) — the surface reads the
//  GRAPH (ids + edges + provenance), not the corpus twin the old list rendered.
//
//  Forget here honours the same "no residue" promise as the MCP forget path
//  (MCPHostController.memoryToolDefinitions): the graph forget cascades the
//  fact's vector + edges, and we chase the dual-written corpus twin by the same
//  content-identity `source_ref` so search_knowledge/ask can't keep a ghost.
//
//  Signed: Kev + claude-opus-4-8, 2026-07-20, Confidence 0.82 (view wiring;
//  verify-owed = on-device click-through). Prior: MemoriesView flat list over
//  documents(kind: .memory).

import Foundation
import M1K3Chat
import M1K3Knowledge
import M1K3Memory

extension AppEnvironment {
    /// Live memory-graph facts, newest first — the explorable Memories surface.
    /// Reads the graph (ids + edges + provenance), not the corpus twin the old
    /// flat list used, so rows can be traversed and traced.
    func memories(includeSuperseded: Bool = false) -> [Memory] {
        (try? memoryStore?.allMemories(includeSuperseded: includeSuperseded)) ?? []
    }

    /// One-hop neighbours of a fact — the "Connections" section. Drilling
    /// deeper is recursion (tap a neighbour → its own detail), so one hop per
    /// level keeps the graph legible instead of dumping a 2-hop blob.
    func relatedMemories(to id: UUID) -> [Memory] {
        (try? memoryStore?.related(to: id, maxHops: 1)) ?? []
    }

    /// The correction lineage behind a fact ("how did you learn this?"),
    /// oldest first. Pure `SupersessionChain` over the full store (superseded
    /// rows are kept as history); a lone fact is its own single-item chain.
    func supersessionHistory(for memory: Memory) -> [Memory] {
        let all = (try? memoryStore?.allMemories(includeSuperseded: true)) ?? []
        return SupersessionChain.history(endingAt: memory, in: all)
    }

    /// Free-text interrogation of the graph ("what do you know about X?"):
    /// hybrid recall through the SAME embedder the dual-write stores into
    /// (mirrors the MCP `recall` handler). Empty/whitespace query → nothing;
    /// any failure degrades to empty rather than surfacing an error to the UI.
    func interrogateMemories(_ query: String, limit: Int = 12) async -> [Memory] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let memoryStore else { return [] }
        guard let vector = try? await embedder.embedQuery(trimmed) else { return [] }
        // Recall bar follows the ACTIVE embedder's cone — the Settings toggle
        // (switchEmbeddings) can put the Mac on hashing, whose measured floor
        // sits far below the qwen default (EmbedderFloors, PR #89).
        let hits = (try? memoryStore.recall(
            query: trimmed, queryVector: vector, limit: limit,
            threshold: EmbedderFloors.forFingerprint(embedder.fingerprint).memory
        )) ?? []
        return hits.map(\.memory)
    }

    /// Forget a graph fact by id — THE consent primitive. Cascades the graph
    /// (vector + edges via `MemoryStore.forget`) AND the dual-written corpus
    /// twin, matched by the same `source_ref` the remember dedup uses, so
    /// "forget" leaves no residue in the RAG surface either.
    ///
    /// Known bound (shared with the MCP path): if the corpus-twin delete fails
    /// after the graph delete commits, the graph fact is gone but the twin may
    /// linger until the next reconcile — logged there, best-effort here.
    @discardableResult
    func forgetMemory(_ memory: Memory) -> Bool {
        guard let memoryStore else { return false }
        let gone = (try? memoryStore.forget(id: memory.id)) ?? false
        guard gone else { return false }

        let ref = MemoryDistillationCoordinator.factSourceRef(memory.text)
        if let twinID = try? store.itemID(forSourceRef: ref) {
            _ = try? store.deleteItem(id: twinID)
            Task { await spotlightDeindex(id: twinID) }
        }
        refreshCounts()
        return true
    }
}
