//
//  MemoryEditorTests.swift
//  M1K3MemoryChatBridgeTests
//
//  #699: a Memories edit and a Memories forget, over the REAL stores both shells wire (a
//  MemoryStore graph, a KnowledgeStore corpus behind a DocumentIngester, the hashing
//  embedder). An edit is a supersede in both stores: the row is re-read, never trusted from
//  the screen that showed it; the corpus takes the new wording before the old one leaves;
//  a same-identity edit keeps one live twin; an edit back to a retired wording restores it.
//  A forget of an edited fact takes the wording it replaced with it, so editing a detail
//  away and then forgetting the fact can never bring the old wording back.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85, Prior: none (new file)
//

import Foundation
@testable import M1K3Chat
@testable import M1K3Knowledge
import M1K3Memory
@testable import M1K3MemoryChatBridge
import Testing

private struct Boom: Error {}

/// An embedder that is down: every embed throws.
private struct DownEmbedder: EmbeddingService {
    let dimension = 3
    let fingerprint = "down"
    func embed(_: String) async throws -> [Float] {
        throw Boom()
    }

    func isAvailable() async -> Bool {
        false
    }
}

/// The graph, the corpus and the embedder the app holds.
private struct Stores {
    let graph: MemoryStore
    let corpus: KnowledgeStore
    let ingester: DocumentIngester
    let embedder = HashingEmbeddingService()

    init() throws {
        graph = try MemoryStore(path: nil)
        corpus = try KnowledgeStore()
        ingester = DocumentIngester(store: corpus, embedder: HashingEmbeddingService())
    }

    /// A fact written the way the distiller writes one: corpus twin and graph node, same text.
    @discardableResult
    func seed(
        _ text: String, kind: MemoryKind = .style, source: String = "distilled", title: String? = nil,
        supersedes: UUID? = nil
    ) async throws -> Memory {
        _ = try await ingester.ingest(
            title: text, text: text, sourceRef: MemoryDistillationCoordinator.factSourceRef(text),
            kind: .memory, source: .distilled
        )
        let memory = Memory(kind: kind, text: text, title: title, source: source)
        let vector = try await embedder.embed(memory.embeddingText)
        try graph.remember(memory, embedding: vector, supersedes: supersedes)
        return memory
    }

    func editor(embedder: (any EmbeddingService)? = nil) -> MemoryEditor {
        MemoryEditor(graph: graph, corpus: corpus, ingester: ingester, embedder: embedder ?? self.embedder)
    }

    func edit(_ id: UUID, to text: String, embedder: (any EmbeddingService)? = nil) async throws -> Memory? {
        try await editor(embedder: embedder).edit(id, to: text)
    }

    func twin(_ text: String) throws -> KnowledgeItem? {
        try corpus.itemID(forSourceRef: MemoryDistillationCoordinator.factSourceRef(text))
            .flatMap { try corpus.item(id: $0) }
    }

    func liveTexts() throws -> [String] {
        try graph.allMemories().map(\.text)
    }
}

private let short = "The user prefers short answers."
private let long = "The user prefers long, detailed answers."
private let metric = "The user prefers metric units."

struct MemoryEditorTests {
    // MARK: - Edit

    @Test("an edit supersedes in the graph and the corpus: one live row, the old wording in its lineage")
    func editSupersedesInBothStores() async throws {
        let stores = try Stores()
        let old = try await stores.seed(short)

        let edited = try #require(try await stores.edit(old.id, to: "  \(long)  "))

        #expect(edited.text == long) // trimmed
        #expect(edited.kind == .style)
        #expect(edited.source == MemoryEditor.editSource)
        #expect(MemoryProvenance(source: edited.source) == .youToldMe)
        #expect(try stores.graph.liveStyleTexts() == [long])
        let all = try stores.graph.allMemories(includeSuperseded: true)
        #expect(SupersessionChain.history(endingAt: edited, in: all).map(\.text) == [short, long])
        #expect(try stores.twin(short)?.kind == .memorySuperseded)
        #expect(try stores.twin(long)?.kind == .memory)
        #expect(try stores.corpus.allItems(kind: .memory).count == 1)
    }

    @Test("an edit carries the row's title, so an MCP fact keeps its discriminating context")
    func editKeepsTheTitle() async throws {
        let stores = try Stores()
        let old = try await stores.seed(metric, kind: .preference, source: "mcp:remember", title: "Units")

        let edited = try #require(try await stores.edit(old.id, to: "The user prefers imperial units."))

        #expect(edited.title == "Units")
    }

    @Test("empty or unchanged text is refused with nothing changed")
    func emptyOrUnchangedIsRefused() async throws {
        let stores = try Stores()
        let old = try await stores.seed(short)

        #expect(try await stores.edit(old.id, to: "   ") == nil)
        #expect(try await stores.edit(old.id, to: short) == nil)
        #expect(try stores.graph.allMemories(includeSuperseded: true).count == 1)
    }

    @Test("a row corrected since the screen loaded it is refused: the store is read, never the screen's copy")
    func staleRowIsRefused() async throws {
        let stores = try Stores()
        let old = try await stores.seed(short)
        // A distillation corrects it while its detail screen is open.
        try await stores.seed(long, supersedes: old.id)

        #expect(try await stores.edit(old.id, to: "The user prefers medium answers.") == nil)
        #expect(try stores.liveTexts() == [long]) // one live head, never two
        #expect(try await stores.edit(UUID(), to: "anything") == nil) // a row that is gone
    }

    @Test("an edit into the wording another live fact already says is refused, never double-listed")
    func editIntoAnotherLiveFactIsRefused() async throws {
        let stores = try Stores()
        let old = try await stores.seed(short)
        try await stores.seed(metric, kind: .preference)

        #expect(try await stores.edit(old.id, to: "the user prefers metric units") == nil)
        #expect(try Set(stores.liveTexts()) == [short, metric])
    }

    @Test("a punctuation-only edit supersedes in the graph and keeps exactly one live corpus twin")
    func punctuationOnlyEditKeepsOneLiveTwin() async throws {
        let stores = try Stores()
        let old = try await stores.seed("The user prefers short answers")

        let edited = try #require(try await stores.edit(old.id, to: short))

        #expect(try stores.liveTexts() == [edited.text])
        #expect(try stores.corpus.allItems(kind: .memory).count == 1)
        #expect(try stores.corpus.allItems(kind: .memorySuperseded).isEmpty)
    }

    @Test("editing back to the earlier wording restores its corpus twin: one live twin, one retired")
    func editBackRestoresTheEarlierWording() async throws {
        let stores = try Stores()
        let old = try await stores.seed(short)
        let first = try #require(try await stores.edit(old.id, to: long))

        let back = try #require(try await stores.edit(first.id, to: short))

        #expect(try stores.liveTexts() == [back.text])
        #expect(try stores.twin(short)?.kind == .memory)
        #expect(try stores.twin(long)?.kind == .memorySuperseded)
        #expect(try stores.corpus.allItems(kind: .memory).count == 1)
    }

    @Test("a failed embed changes nothing in either store")
    func failedEmbedChangesNothing() async throws {
        let stores = try Stores()
        let old = try await stores.seed(short)

        await #expect(throws: Boom.self) {
            try await stores.edit(old.id, to: long, embedder: DownEmbedder())
        }
        #expect(try stores.liveTexts() == [short])
        #expect(try stores.twin(short)?.kind == .memory)
        #expect(try stores.twin(long) == nil)
    }

    @Test("re-stating the old wording after an edit revives it in both stores and demotes the edit")
    func restatingAfterAnEditRevivesIt() async throws {
        let stores = try Stores()
        let old = try await stores.seed(short)
        _ = try #require(try await stores.edit(old.id, to: long))

        let written = try await MemoryDistillationCoordinator(
            distiller: Scripted(facts: [DistilledFact(text: short, kind: .style)]),
            ingester: stores.ingester, store: stores.corpus, embedder: stores.embedder,
            graph: DistilledFactGraphAdapter(store: stores.graph), selfNames: .none
        ).distillAndStore(turns: [ChatTurn(role: .user, text: "actually, short answers please")])

        #expect(written == 1)
        #expect(try stores.graph.liveStyleTexts() == [short])
        #expect(try stores.twin(short)?.kind == .memory)
        #expect(try stores.twin(long)?.kind == .memorySuperseded)
    }

    // MARK: - Forget

    @Test("forgetting an edited fact forgets the wording it replaced too: nothing revives, no twin is left")
    func forgetTakesTheEditedAwayWording() async throws {
        let stores = try Stores()
        let old = try await stores.seed(short)
        let edited = try #require(try await stores.edit(old.id, to: long))

        let twins = try #require(try stores.editor().forget(edited.id))

        #expect(twins.count == 2)
        #expect(try stores.graph.allMemories(includeSuperseded: true).isEmpty)
        #expect(try stores.graph.liveStyleTexts().isEmpty)
        #expect(try stores.twin(short) == nil)
        #expect(try stores.twin(long) == nil)
    }

    @Test("a chain of edits goes with its head")
    func forgetTakesAChainOfEdits() async throws {
        let stores = try Stores()
        let first = try await stores.seed(short)
        let second = try #require(try await stores.edit(first.id, to: long))
        let third = try #require(try await stores.edit(second.id, to: "The user prefers medium answers."))

        _ = try stores.editor().forget(third.id)

        #expect(try stores.graph.allMemories(includeSuperseded: true).isEmpty)
        #expect(try stores.corpus.allItems(kind: .memory).isEmpty)
        #expect(try stores.corpus.allItems(kind: .memorySuperseded).isEmpty)
    }

    @Test("forgetting a head that is not an edit keeps the store's one-step undo: its predecessor is live again")
    func forgetOfACorrectionStillUndoes() async throws {
        let stores = try Stores()
        let old = try await stores.seed(short)
        let correction = try await stores.seed(long, supersedes: old.id)

        let twins = try #require(try stores.editor().forget(correction.id))

        #expect(twins.count == 1)
        #expect(try stores.liveTexts() == [short])
        #expect(try stores.twin(long) == nil)
    }

    @Test("an edit of a correction takes the corrected wording with it, and the one before revives, as undo does")
    func forgetOfAnEditedCorrection() async throws {
        let stores = try Stores()
        let original = try await stores.seed(short)
        let correction = try await stores.seed(long, supersedes: original.id)
        let edited = try #require(try await stores.edit(correction.id, to: "The user prefers medium answers."))

        _ = try stores.editor().forget(edited.id)

        #expect(try stores.liveTexts() == [short])
        #expect(try stores.graph.allMemories(includeSuperseded: true).count == 1)
    }

    @Test("forgetting an id no row has is nil")
    func forgetUnknownIsNil() throws {
        let stores = try Stores()
        #expect(try stores.editor().forget(UUID()) == nil)
    }
}

private struct Scripted: MemoryDistilling {
    let facts: [DistilledFact]
    func distill(turns _: [ChatTurn]) async throws -> [DistilledFact] {
        facts
    }
}
