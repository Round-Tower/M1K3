//
//  MemoryStyleKind.swift
//  M1K3Memory
//
//  #699 Phase 1: the `style` kind — how the user asked to be answered (length,
//  format, register: "shorter answers", "no lists"). It is written only from the
//  user's own asks: the distiller under the attribution and explicit-ask fences
//  (M1K3Chat/StyleAskFence.swift) and the Memories editor. It is the first kind
//  that renders into the persona (the style line `M1K3Persona.compose` adds), so
//  the app reads it back newest first with `liveStyleTexts()`.
//
//  Deliberately NOT in `MemoryKind.catalogued`: that list is what MCP `remember`
//  and App Intents may label a fact with, and an agent must not write how the user
//  wants to be spoken to. `MemoryKind(catalogued: "style")` stays `.note`, pinned.
//
//  Lives in its own file, beside the vocabulary rather than in it, so the kind and
//  its read need no edit to MemoryStore.swift (the file that registers the GRDB
//  migrations). The column is an open string, so a new kind needs no migration.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85 (pinned in
//  MemoryStyleKindTests; whether the distiller files real asks under it is the
//  on-device half, measured by MEMSTAT and the chateval style arm), Prior: none (new file)
//  Review: Kev + claude-opus-5.5, 2026-10-27 (pre-push review fold) — `liveStyleMemories()` returns the rows,
//  and `reviewableMemories` is the Memories list: its newest-first window plus every live style row past it, so
//  what rides every prompt is always visible and forgettable. Confidence 0.85.
//

public extension MemoryKind {
    /// How the user asked to be answered ("The user prefers short answers.").
    /// Uncatalogued on purpose (see the file header).
    static let style = MemoryKind(rawValue: "style")
}

public extension MemoryStore {
    /// Every live `.style` fact's text, newest first — what the persona's style line
    /// renders from. Reads the WHOLE live set, sized by its own count, never a fixed
    /// window: under `allMemories()`'s default 500 an old ask would silently drop out
    /// of the persona once the graph grew past it (the PR #94 lesson). The slack
    /// covers a write landing between the count and the read. A store with no style
    /// rows costs one grouped count.
    func liveStyleTexts() throws -> [String] {
        try liveStyleMemories().map(\.text)
    }

    /// Every live `.style` row, newest first, over the whole live set (see `liveStyleTexts`).
    func liveStyleMemories() throws -> [Memory] {
        guard try (liveCountsByKind()[MemoryKind.style.rawValue] ?? 0) > 0 else { return [] }
        let window = try liveCount() + 64
        return try allMemories(limit: window).filter { $0.kind == .style }
    }

    /// The Memories list: `allMemories`' newest-first window plus every live style row the
    /// window missed, merged newest first. Visibility is the other half of consent: a row
    /// that rides every system prompt must never sit past the list's reach, unseen and
    /// unforgettable, however many newer facts the graph holds.
    func reviewableMemories(includeSuperseded: Bool = false, limit: Int = 500) throws -> [Memory] {
        let window = try allMemories(includeSuperseded: includeSuperseded, limit: limit)
        let listed = Set(window.map(\.id))
        let missing = try liveStyleMemories().filter { !listed.contains($0.id) }
        guard !missing.isEmpty else { return window }
        return (window + missing).sorted { $0.createdAt > $1.createdAt }
    }
}
