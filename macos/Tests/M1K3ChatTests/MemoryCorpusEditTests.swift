//
//  MemoryCorpusEditTests.swift
//  M1K3ChatTests
//
//  #699: the corpus half of a Memories edit (`MemoryDistillationCoordinator.applyEdit`), over a
//  real KnowledgeStore and DocumentIngester. The review found the app's first version demoted the
//  old twin before ingesting the new one and missed two shapes. Pinned here: the new wording is
//  ingested first and the ledger holds ids only; a punctuation-only edit moves nothing; a failed
//  ingest leaves the old twin live and is audited without the fact's text; an edit back to a
//  retired wording restores it; and re-stating the old wording revives it over the edit.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85, Prior: none (new file)
//

import Foundation
@testable import M1K3Chat
@testable import M1K3Knowledge
import Testing

private struct Scripted: MemoryDistilling {
    let facts: [DistilledFact]
    func distill(turns _: [ChatTurn]) async throws -> [DistilledFact] {
        facts
    }
}

struct MemoryCorpusEditTests {
    private static let short = "The user prefers short answers."
    private static let long = "The user prefers long, detailed answers."

    private func corpus() throws -> (KnowledgeStore, DocumentIngester) {
        let store = try KnowledgeStore()
        return (store, DocumentIngester(store: store, embedder: HashingEmbeddingService()))
    }

    private func seed(_ text: String, into ingester: DocumentIngester) async throws -> UUID {
        try await ingester.ingest(
            title: text, text: text, sourceRef: MemoryDistillationCoordinator.factSourceRef(text),
            kind: .memory, source: .distilled
        ).itemID
    }

    private func twin(_ text: String, in store: KnowledgeStore) throws -> KnowledgeItem? {
        try store.itemID(forSourceRef: MemoryDistillationCoordinator.factSourceRef(text))
            .flatMap { try store.item(id: $0) }
    }

    @Test("an edit ingests the new wording live, retires the old twin, and records the ledger by ids")
    func editSupersedesTheCorpusTwin() async throws {
        let (store, ingester) = try corpus()
        let oldID = try await seed(Self.short, into: ingester)

        let outcome = await MemoryDistillationCoordinator.applyEdit(
            from: Self.short, to: Self.long, store: store, ingester: ingester
        )

        #expect(outcome == .superseded)
        #expect(try store.item(id: oldID)?.kind == .memorySuperseded)
        let edited = try #require(try twin(Self.long, in: store))
        #expect(edited.kind == .memory)
        #expect(edited.source == .user)
        #expect(try store.meta(key: MemoryDistillationCoordinator.supersededLinkKey(oldID)) == edited.id.uuidString)
        #expect(try store.allItems(kind: .memory).count == 1)
    }

    @Test("a case- or punctuation-only edit moves nothing: the live twin already answers to it")
    func punctuationOnlyEditIsUnchanged() async throws {
        let (store, ingester) = try corpus()
        let oldID = try await seed(Self.short, into: ingester)

        let outcome = await MemoryDistillationCoordinator.applyEdit(
            from: Self.short, to: "the user prefers SHORT answers", store: store, ingester: ingester
        )

        #expect(outcome == .unchanged)
        #expect(try store.item(id: oldID)?.kind == .memory)
        #expect(try store.allItems(kind: .memory).count == 1)
        #expect(try store.meta(key: MemoryDistillationCoordinator.supersededLinkKey(oldID)) == nil)
    }

    @Test("a failed ingest demotes nothing: the old twin stays live, and the divergence is audited by ids only")
    func failedIngestKeepsTheOldTwinLive() async throws {
        let (store, ingester) = try corpus()
        let oldID = try await seed(Self.short, into: ingester)
        nonisolated(unsafe) var audit: [String] = []

        let outcome = await MemoryDistillationCoordinator.applyEdit(
            from: Self.short, to: "<html> answers </html>", store: store, ingester: ingester,
            auditSink: { audit.append($0) }
        )

        #expect(outcome == .failed)
        #expect(try store.item(id: oldID)?.kind == .memory)
        #expect(audit.count == 1)
        #expect(audit.first?.contains(oldID.uuidString) == true)
        #expect(audit.first?.contains("answers") == false) // never the fact's text
    }

    @Test("an edit back to a wording an earlier edit retired restores that row; one live twin, the ledger flipped")
    func editBackRestoresTheRetiredWording() async throws {
        let (store, ingester) = try corpus()
        let shortID = try await seed(Self.short, into: ingester)
        _ = await MemoryDistillationCoordinator.applyEdit(
            from: Self.short, to: Self.long, store: store, ingester: ingester
        )
        let longID = try #require(try twin(Self.long, in: store)?.id)

        let outcome = await MemoryDistillationCoordinator.applyEdit(
            from: Self.long, to: Self.short, store: store, ingester: ingester
        )

        #expect(outcome == .superseded)
        #expect(try store.item(id: shortID)?.kind == .memory)
        #expect(try store.item(id: longID)?.kind == .memorySuperseded)
        #expect(try store.allItems(kind: .memory).map(\.id) == [shortID])
        #expect(try store.meta(key: MemoryDistillationCoordinator.supersededLinkKey(longID)) == shortID.uuidString)
        #expect(try store.meta(key: MemoryDistillationCoordinator.supersededLinkKey(shortID)) == nil)
    }

    @Test("re-stating the old wording after an edit revives it and demotes the edit, through the ledger")
    func restatingTheOldWordingRevivesIt() async throws {
        let (store, ingester) = try corpus()
        let shortID = try await seed(Self.short, into: ingester)
        _ = await MemoryDistillationCoordinator.applyEdit(
            from: Self.short, to: Self.long, store: store, ingester: ingester
        )
        let longID = try #require(try twin(Self.long, in: store)?.id)
        let restate = MemoryDistillationCoordinator(
            distiller: Scripted(facts: [DistilledFact(text: Self.short, kind: .style)]),
            ingester: ingester, store: store, embedder: HashingEmbeddingService(), selfNames: .none
        )

        let written = try await restate.distillAndStore(turns: [
            ChatTurn(role: .user, text: "actually, short answers please"),
        ])

        #expect(written == 1)
        #expect(try store.item(id: shortID)?.kind == .memory)
        #expect(try store.item(id: longID)?.kind == .memorySuperseded)
    }
}
