//
//  DistilledFactGraphAdapter.swift
//  M1K3MemoryChatBridge
//
//  A leaf bridge between two independent modules: it adapts the concrete
//  M1K3Memory `MemoryStore` graph to M1K3Chat's `DistilledFactGraphWriting` seam,
//  so the distillation coordinator mirrors NEW facts into the temporal graph
//  WITHOUT M1K3Chat depending on M1K3Memory (nor the reverse). Distilled facts
//  land as nodes tagged `distilled`, carrying the distiller's classification
//  (DistilledFactKind rawValues deliberately match the MemoryKind constants, so
//  the mapping is the identity on strings — MemoryKind is an open string enum).
//  The embedding is the coordinator's own (computed with the
//  embedder recall also queries with), so graph writes and recall share one space.
//
//  This lived in M1K3App and was app-target-only, which stranded the iOS/visionOS
//  shell (it couldn't turn on chat memory auto-capture). Relocated here — a module
//  that depends on EXACTLY [M1K3Chat, M1K3Memory] and nothing depends back on —
//  so BOTH shells wire the same dual-write. The Chat-must-not-depend-on-Memory
//  seam is preserved (folding into either module would invert the layering).
//
//  Signed: Kev + claude-opus-4-8, 2026-07-07, Confidence 0.85, Prior: Unknown
//
//  Review (2026-07-08, Kev + claude-fable-5): carries the new DistilledFactKind
//  through to MemoryKind — was hardcoded `.note` (the in-source TODO on
//  MemoryKind). Kev's product call: the distiller classifies.
//  Review (2026-07-30, Kev + claude-fable-5): Tier-2 write-time repair — the
//  seam gains supersede-by-text and revive-on-reassert (scratch/dream-cycle/
//  SPEC.md §2); fact text is the corpus↔graph join key.
//

import M1K3Chat
import M1K3Memory

public struct DistilledFactGraphAdapter: DistilledFactGraphWriting {
    public let store: MemoryStore

    public init(store: MemoryStore) {
        self.store = store
    }

    public func writeDistilledFact(
        _ text: String, kind: DistilledFactKind, embedding: [Float], superseding oldFactText: String?
    ) async throws {
        let memory = Memory(kind: MemoryKind(rawValue: kind.rawValue), text: text, source: "distilled")
        // Text is the join key (the dual-write stores the SAME fact text in
        // both stores). A miss — no live node carries the old text — degrades
        // to a plain insert rather than dropping the new fact.
        //
        // Source-trust (spec §1/B1): this supersedes whatever live node
        // matches, INCLUDING an `mcp:remember`-sourced one — the allowed
        // direction. The forbidden direction (an MCP fact auto-winning) can't
        // occur through this seam: the MCP remember path never calls it.
        guard let oldFactText, let old = try store.liveMemory(matchingText: oldFactText) else {
            try store.rememberConnected(memory, embedding: embedding)
            return
        }
        try store.remember(memory, embedding: embedding, supersedes: old.id)
    }

    public func reviveFact(_ text: String, kind: DistilledFactKind, embedding: [Float]) async throws -> String? {
        let memory = Memory(kind: MemoryKind(rawValue: kind.rawValue), text: text, source: "distilled")
        // Re-assertion repair (spec finding #8): supersede the chain's live
        // head with a fresh node carrying the re-asserted text. No superseded
        // chain matching the text → plain insert, nothing supplanted.
        guard let head = try store.liveSuccessor(ofText: text) else {
            try store.rememberConnected(memory, embedding: embedding)
            return nil
        }
        try store.remember(memory, embedding: embedding, supersedes: head.id)
        return head.text
    }
}
