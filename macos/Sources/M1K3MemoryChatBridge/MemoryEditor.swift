//
//  MemoryEditor.swift
//  M1K3MemoryChatBridge
//
//  #699: the Memories list's edit and forget across BOTH stores, here rather than in the
//  app shell so `swift test` reaches them (MemoryEditorTests runs them over real stores).
//  The graph half lives here (this module sees M1K3Memory); the corpus half of an edit is
//  `MemoryDistillationCoordinator.applyEdit`, beside the supersede, revive and ledger rules
//  it must keep.
//
//  An edit is a SUPERSEDE, never a rewrite in place: the graph gets a new node (source
//  "user:edit", which reads as "you told me") that supersedes the old one, so "How I
//  learned this" shows the change. The row is re-read from the store first, never trusted
//  from the screen that showed it: a distillation may have corrected it since, and
//  superseding a corrected row would leave two live heads for one fact.
//
//  A forget of an edited fact takes the wording it replaced with it. The store's forget
//  revives whatever the row superseded (one-step undo), so without this, editing a detail
//  away and then forgetting the fact would bring the old wording back, into the persona
//  for a style row. The walk follows edits only: past the first row that is not an edit,
//  the store's own undo stands.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.8 (pinned over real stores;
//  the forget walk is a product rule, Kev's call), Prior: none (new file)
//

import Foundation
import M1K3Chat
import M1K3Knowledge
import M1K3Memory

public struct MemoryEditor: Sendable {
    /// The provenance an edit carries; `MemoryProvenance` reads it as "you told me".
    public static let editSource = "user:edit"

    public let graph: MemoryStore
    public let corpus: KnowledgeStore
    public let ingester: DocumentIngester
    public let embedder: any EmbeddingService
    /// Receives a corpus/graph divergence line (ids only) when the corpus half fails.
    public let auditSink: (@Sendable (String) -> Void)?

    public init(
        graph: MemoryStore,
        corpus: KnowledgeStore,
        ingester: DocumentIngester,
        embedder: any EmbeddingService,
        auditSink: (@Sendable (String) -> Void)? = nil
    ) {
        self.graph = graph
        self.corpus = corpus
        self.ingester = ingester
        self.embedder = embedder
        self.auditSink = auditSink
    }

    /// Edit the fact `id` to `text`, as a supersede in the graph and then the corpus.
    /// Returns the new row, or nil with nothing changed when the edit is refused: empty or
    /// unchanged text, a row that is gone or already corrected, or wording another live
    /// fact already says (it would be listed twice). Throws, with nothing changed, when
    /// the embed or the graph write fails. A corpus failure after the graph committed is
    /// logged and audited by `applyEdit`, never thrown: the edit stands.
    public func edit(_ id: UUID, to text: String) async throws -> Memory? {
        let newText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newText.isEmpty, let current = try graph.memory(id: id) else { return nil }
        guard current.supersededBy == nil, newText != current.text else { return nil }
        let identity = MemoryFactNormalizer.normalize(newText)
        let sameWording = try graph.liveMemory(where: { MemoryFactNormalizer.normalize($0) == identity })
        if let sameWording, sameWording.id != current.id { return nil }
        let edited = Memory(kind: current.kind, text: newText, title: current.title, source: Self.editSource)
        let vector = try await embedder.embed(edited.embeddingText)
        try graph.rememberConnected(edited, embedding: vector, supersedes: current.id)
        _ = await MemoryDistillationCoordinator.applyEdit(
            from: current.text, to: newText, store: corpus, ingester: ingester, auditSink: auditSink
        )
        return edited
    }

    /// Forget the fact `id` everywhere: its graph node, and when it is an edit, the wording
    /// each edit replaced, back to the first row that is not an edit; then every corpus twin
    /// of what was forgotten. Oldest first, so no forget revives a row this one is about to
    /// remove. Returns the corpus item ids deleted (the app de-indexes them from Spotlight),
    /// or nil when no row has `id`.
    public func forget(_ id: UUID) throws -> [UUID]? {
        guard let head = try graph.memory(id: id) else { return nil }
        var doomed = [head]
        if head.source == Self.editSource {
            let all = try graph.allMemories(includeSuperseded: true, limit: graph.totalCount() + 64)
            var cursor = head
            while cursor.source == Self.editSource {
                let replaced = all.first { $0.supersededBy == cursor.id }
                guard let replaced, !doomed.contains(where: { $0.id == replaced.id }) else { break }
                doomed.append(replaced)
                cursor = replaced
            }
        }
        for memory in doomed.reversed() {
            _ = try graph.forget(id: memory.id)
        }
        return doomed.compactMap { memory in
            let ref = MemoryDistillationCoordinator.factSourceRef(memory.text)
            guard let twinID = try? corpus.itemID(forSourceRef: ref),
                  (try? corpus.deleteItem(id: twinID)) == true
            else { return nil }
            return twinID
        }
    }
}
