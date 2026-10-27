//
//  ImportForget.swift
//  M1K3Import
//
//  "Forget everything from this import" (#711) — one action, possible because every row an import
//  writes carries its `import/<provider>/<day>` tag. Graph rows go through MemoryStore's
//  forget-by-source (the consent cascade; a row the import superseded is live again), corpus memory
//  rows through the coordinator's forget (the supersede ledger restores their twins), and then the
//  filed conversations. Order matters: the corpus restore reads the ledger before the rows go.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85.
//  Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-27 (pre-push review fold) — documented as blocking (each store's half is
//  now one transaction; the three halves are separate, and idempotent, so a retry converges). Confidence 0.85.

import Foundation
import M1K3Chat
import M1K3Knowledge
import M1K3Memory

public struct ImportForgetReceipt: Sendable, Equatable {
    public let graphMemoriesForgotten: Int
    public let corpusMemoriesForgotten: Int
    public let conversationsForgotten: Int

    public init(graphMemoriesForgotten: Int, corpusMemoriesForgotten: Int, conversationsForgotten: Int) {
        self.graphMemoriesForgotten = graphMemoriesForgotten
        self.corpusMemoriesForgotten = corpusMemoriesForgotten
        self.conversationsForgotten = conversationsForgotten
    }
}

public enum ImportForget {
    /// Remove every row `tag` wrote from both stores and revive what those rows superseded.
    /// Rows other writers wrote, and other imports' rows, are untouched. Blocking (one write
    /// transaction per store half): run it off the main actor, as propose and commit are.
    /// Idempotent: a second call finds nothing and returns zeros.
    public static func forget(
        tag: ImportSourceTag, knowledgeStore: KnowledgeStore, memoryStore: MemoryStore
    ) throws -> ImportForgetReceipt {
        let graph = try memoryStore.forget(source: tag.graphSource)
        let corpus = try MemoryDistillationCoordinator.forgetCorpus(source: tag.knowledgeSource, in: knowledgeStore)
        let conversations = try knowledgeStore.deleteItems(source: tag.knowledgeSource)
        return ImportForgetReceipt(
            graphMemoriesForgotten: graph, corpusMemoriesForgotten: corpus, conversationsForgotten: conversations
        )
    }
}
