//
//  DemoSeeder.swift
//  M1K3Screengrab
//
//  Writes the persona into the REAL stores under the screengrab root. Two
//  halves because the shells build them at different moments: history is
//  synchronous and must land BEFORE ChatSession's resume-most-recent read;
//  memories + documents need the embedder, so they run as a launch Task.
//  Idempotent — the suite launches the app once per plate.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-07, Confidence 0.85 (driven against
//  the real GRDB stores in tests), Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-09-08 — idempotency is content-based as
//  well as marker-based (review: a kill between row and marker seeded twice);
//  persona edits reset by clearing the sibling root (capture.sh does it per run).
//  Confidence now 0.85.
//  Review: Kev + claude-opus-5, 2026-09-13 — the hero conversation is RESTORED every launch
//  (and strays dropped, only inside the screengrab root): capture.sh can no longer clear the
//  container under macOS app-data privacy, so a voice turn grew it run over run. Confidence 0.9.
//  Review: Kev + claude-fable-5.1, 2026-09-18 — seeds `DemoPersona.allMemories` (backstory + the five) and then links
//  `constellationEdges`; `link` is idempotent, and the marker + liveCount guards still make the whole seed once-only. Confidence 0.9.
//

import Foundation
import M1K3Chat
import M1K3Knowledge
import M1K3Memory

public enum DemoSeeder {
    private static let historyMarker = ".demo-history-seeded"
    private static let knowledgeMarker = ".demo-knowledge-seeded"

    /// The hero conversation as the newest row, titled, complete — restored on
    /// EVERY launch, not seeded once. A capture run's voice-speaking plate is a
    /// real turn that appends its question and answer to the hero conversation,
    /// and the next run's chat plate showed the exchange three times over
    /// (2026-09-13). The demo root is disposable by design, so a stray
    /// conversation is dropped too: the chat plate resumes the most recent row.
    /// Pruning runs only when `root` IS the screengrab sibling root — a
    /// belt-and-braces guard on top of the shells' `isActive` check, so this
    /// can never touch a live store.
    public static func seedHistory(into history: any ChatHistoryPersisting, root: URL) throws {
        let existing = try history.list()
        let hero = existing.first { $0.title == DemoPersona.heroTitle }
        if root.lastPathComponent == ScreengrabHarness.dataRootName {
            for conversation in existing where conversation.id != hero?.id {
                try history.delete(id: conversation.id)
            }
        }
        let id = hero?.id ?? UUID()
        try history.save(id: id, messages: DemoPersona.heroConversation, updatedAt: Date())
        try history.setTitle(id: id, title: DemoPersona.heroTitle)
        // Already "distilled": the launch catch-up must not mine the seed for memories.
        try history.setDistilledWatermark(id: id, count: DemoPersona.heroConversation.count)
        try Data().write(to: root.appendingPathComponent(historyMarker))
    }

    /// Memories into the graph, documents into the corpus.
    public static func seedKnowledge(
        memory: MemoryStore?,
        ingester: DocumentIngester,
        embedder: any EmbeddingService,
        root: URL
    ) async throws {
        let marker = root.appendingPathComponent(knowledgeMarker)
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        // Content guard (see seedHistory): seeded memories carry the demo source.
        if let memory, try memory.liveCount() > 0 {
            try Data().write(to: marker)
            return
        }
        if let memory {
            // The backstory and the curated five, then the threads between them —
            // the constellation's plate needs a life, not five motes (DemoPersona).
            // `link` is idempotent on (from, to, relation).
            for fact in DemoPersona.allMemories {
                try memory.remember(fact, embedding: await embedder.embed(fact.text))
            }
            for edge in DemoPersona.constellationEdges {
                try memory.link(edge)
            }
        }
        for document in DemoPersona.documents {
            try await ingester.ingest(title: document.title, text: document.text, sourceRef: document.sourceRef)
        }
        try Data().write(to: marker)
    }
}
