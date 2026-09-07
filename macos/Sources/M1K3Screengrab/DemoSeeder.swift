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
//

import Foundation
import M1K3Chat
import M1K3Knowledge
import M1K3Memory

public enum DemoSeeder {
    private static let historyMarker = ".demo-history-seeded"
    private static let knowledgeMarker = ".demo-knowledge-seeded"

    /// The hero conversation as the newest row, titled, complete.
    public static func seedHistory(into history: any ChatHistoryPersisting, root: URL) throws {
        let marker = root.appendingPathComponent(historyMarker)
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        // Content guard: a kill between the row and the marker must not seed twice.
        if try history.list().contains(where: { $0.title == DemoPersona.heroTitle }) {
            try Data().write(to: marker)
            return
        }
        let id = UUID()
        try history.save(id: id, messages: DemoPersona.heroConversation, updatedAt: Date())
        try history.setTitle(id: id, title: DemoPersona.heroTitle)
        // Already "distilled": the launch catch-up must not mine the seed for memories.
        try history.setDistilledWatermark(id: id, count: DemoPersona.heroConversation.count)
        try Data().write(to: marker)
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
            for fact in DemoPersona.memories {
                try memory.remember(fact, embedding: await embedder.embed(fact.text))
            }
        }
        for document in DemoPersona.documents {
            try await ingester.ingest(title: document.title, text: document.text, sourceRef: document.sourceRef)
        }
        try Data().write(to: marker)
    }
}
