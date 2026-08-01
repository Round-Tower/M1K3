//
//  MemoryProvenance.swift
//  M1K3Memory
//
//  Two pure helpers the explorable memory surface leans on, kept out of the
//  view so they're unit-pinned and reusable:
//    · MemoryProvenance — classify a fact's `source` string into the
//      consent-facing "you told me" vs "I noticed" (vs an honest fallback).
//    · SupersessionChain — the correction history behind a live fact, walking
//      `Memory.supersededBy` backwards ("how did you learn this?").
//
//  Both are pure over Memory VALUES — no store, no SQL, no embedder — so the
//  UI stays dumb and this logic is tested in `swift test` (no metallib wall).
//  Display strings stay app-side (String(localized:)); the core exposes intent,
//  not copy.
//
//  Signed: Kev + claude-opus-4-8, 2026-07-20, Confidence 0.85. Prior: the
//  KnowledgeItemSource .user/.distilled mapping (M1K3Knowledge), generalised to
//  the graph's richer source vocabulary ("mcp:remember", "chat:auto-distill",
//  "user:settings").

import Foundation

/// Who authored a memory, derived from its open-vocabulary `source` string.
/// The graph stores richer sources than the corpus twin's two-way user/distilled
/// (e.g. "mcp:remember", "chat:auto-distill", "user:settings"); this collapses
/// them to the consent-facing distinction the surface shows. A source it can't
/// place is `.remembered` — it misclassifies toward honesty, never crashes
/// (the same doctrine as `MemoryKind(catalogued:)`).
public enum MemoryProvenance: Equatable, Sendable {
    /// The user said it explicitly (the `remember` tool, manual entry, Settings).
    case youToldMe
    /// The background distillation loop noticed it in a conversation.
    case iNoticed
    /// Unknown/legacy writer — surfaced plainly rather than guessed.
    case remembered

    public init(source: String) {
        let s = source.lowercased()
        if s.contains("distill") {
            self = .iNoticed
        } else if s.hasPrefix("user") || s.hasPrefix("mcp:remember") {
            self = .youToldMe
        } else {
            self = .remembered
        }
    }
}

/// The correction history behind a fact — its supersession lineage.
///
/// Supersession is correction, not deletion: a superseded row is kept
/// (`Memory.supersededBy` points at whatever replaced it) so the surface can
/// answer "how did you learn this?" by walking that lineage backwards from the
/// live fact. Pure over the supplied Memory set — the caller feeds
/// `allMemories(includeSuperseded: true)`.
public enum SupersessionChain {
    /// Every (transitive) predecessor of `memory` plus `memory` itself, oldest
    /// first. Robust to a corrector that superseded several rows at once (a
    /// merge) — it collects all ancestors rather than assuming a single line —
    /// and cycle-safe via a visited set, so a malformed loop terminates instead
    /// of hanging.
    public static func history(endingAt memory: Memory, in all: [Memory]) -> [Memory] {
        // predecessors[x] = the rows whose supersededBy points at x.
        var predecessors: [UUID: [Memory]] = [:]
        for m in all {
            if let replacedBy = m.supersededBy {
                predecessors[replacedBy, default: []].append(m)
            }
        }

        var collected: [UUID: Memory] = [memory.id: memory]
        var queue: [UUID] = [memory.id]
        while let id = queue.popLast() {
            for predecessor in predecessors[id] ?? [] where collected[predecessor.id] == nil {
                collected[predecessor.id] = predecessor
                queue.append(predecessor.id)
            }
        }

        return collected.values.sorted { $0.createdAt < $1.createdAt }
    }
}
