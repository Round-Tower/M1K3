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
//  Review: Kev + claude-opus-5.5, 2026-10-27 — #699 Phase 1: `refreshUserStyle` reads the live `.style`
//  rows newest first into the persona (launch, after a distillation that wrote, after forget and edit),
//  and `editMemory` makes a fact editable as a SUPERSEDE (source "user:edit", lineage kept). Confidence 0.8
//  (verify-by-launch owed: state a style, leave the chat, see the row, relaunch, read the next prompt).
//  Review: Kev + claude-opus-5.5, 2026-10-27 (pre-push review fold) — the edit's corpus half demoted the old
//  twin BEFORE ingesting the new one, swallowed failures, and missed the same-identity and edit-back cases;
//  it also trusted the screen's copy of the row. Edit and forget now call `MemoryEditor` (M1K3MemoryChatBridge,
//  tested over real stores): the row is re-read, the corpus takes the new wording first, and forgetting an
//  edited fact takes the wording it replaced. The list carries every live style row past its window
//  (`reviewableMemories`), and the style re-read moved to `refreshCounts()`, the seam MCP forget_memory
//  also calls. Confidence 0.8 (the same verify-by-launch owed).
//  Review: Kev + claude-opus-5.5, 2026-10-28 — the style re-read goes through the persona's refresh gate: a
//  forget's refresh and the distiller's didWrite could interleave, and a stale read landing last brought a
//  forgotten ask back (#730 audit). Confidence 0.85.

import Foundation
import M1K3Chat
import M1K3Inference
import M1K3Knowledge
import M1K3Memory
import M1K3MemoryChatBridge
import os

extension AppEnvironment {
    /// Live memory-graph facts, newest first — the explorable Memories surface.
    /// Reads the graph (ids + edges + provenance), not the corpus twin the old
    /// flat list used, so rows can be traversed and traced.
    /// Every live `.style` row is listed however far past the window it sits (#699): what
    /// rides every system prompt must stay visible and forgettable.
    func memories(includeSuperseded: Bool = false) -> [Memory] {
        (try? memoryStore?.reviewableMemories(includeSuperseded: includeSuperseded)) ?? []
    }

    /// Corrected (superseded) facts, newest first — the history lens. The
    /// store's OWN query and row budget, never a partition of the live fetch:
    /// a shared limit would let recent corrected rows displace live rows out
    /// of the window and silently shrink the live list/count (PR #94).
    func correctedMemories() -> [Memory] {
        (try? memoryStore?.supersededMemories()) ?? []
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
    /// An edited fact takes the wording it replaced with it (`MemoryEditor.forget`, #699):
    /// the store's forget revives what a row superseded, so editing a detail away and then
    /// forgetting the fact would otherwise bring the old wording back.
    ///
    /// Known bound (shared with the MCP path): if the corpus-twin delete fails
    /// after the graph delete commits, the graph fact is gone but the twin may
    /// linger until the next reconcile — logged there, best-effort here.
    @discardableResult
    func forgetMemory(_ memory: Memory) -> Bool {
        guard let editor = memoryEditor, let twins = try? editor.forget(memory.id) else { return false }
        for twinID in twins {
            Task { await spotlightDeindex(id: twinID) }
        }
        refreshCounts() // re-reads the stated style too
        return true
    }

    // MARK: - Stated style (#699)

    /// The Memories list's edit and forget over both stores (M1K3MemoryChatBridge, tested
    /// there); nil without a graph.
    private var memoryEditor: MemoryEditor? {
        memoryStore.map { MemoryEditor(graph: $0, corpus: store, ingester: ingester, embedder: embedder) }
    }

    private nonisolated static let memoryEditLog = Logger(subsystem: "app.m1k3", category: "memory-graph")

    /// Re-read the user's stated answer style into the persona: every live `.style`
    /// row, newest first. Cheap when nothing is stored (one grouped count), and a
    /// re-read that finds the same rows leaves the system prompt as it was. Runs at
    /// launch and from `refreshCounts()`, which every memory write and forget calls.
    func refreshUserStyle() {
        Self.refreshUserStyle(from: memoryStore)
    }

    /// The same read for the distillation coordinator's `didWrite` hook, which fires
    /// off the main actor: the persona's box is a Mutex and the store a GRDB queue.
    /// A failed read keeps the style the persona already has rather than clearing it,
    /// and a read that a later refresh overtook is dropped (`UserStyleRefreshGate`).
    nonisolated static func refreshUserStyle(from memoryStore: MemoryStore?) {
        guard let memoryStore else { return }
        M1K3Persona.refreshUserStyle { try memoryStore.liveStyleTexts() }
    }

    /// Edit a fact from the Memories list: a SUPERSEDE in the graph and then the corpus,
    /// by `MemoryEditor.edit` (tested over real stores). The row is re-read from the store,
    /// never trusted from the screen; the corpus takes the new wording before the old one
    /// leaves retrieval, and a corpus failure after the graph committed is logged and
    /// audited there. False, with nothing changed, for empty or unchanged text, a row that
    /// is gone or already corrected, wording another live fact already says, or a failed
    /// embed or graph write.
    @discardableResult
    func editMemory(_ memory: Memory, text: String) async -> Bool {
        guard let editor = memoryEditor else { return false }
        do {
            guard try await editor.edit(memory.id, to: text) != nil else { return false }
        } catch {
            Self.memoryEditLog.error(
                "memory edit failed (nothing changed): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
        refreshCounts() // re-reads the stated style too
        return true
    }
}
