//
//  ConversationKindTests.swift
//  M1K3KnowledgeTests
//
//  #711: an imported ChatGPT / Claude conversation is filed as a `.conversation` knowledge item —
//  retrieved and cited on the DOCUMENT lane like a document, never a memory, swept at launch like
//  every retrievable kind, and not donated to Spotlight (the opt-in set stays document + call
//  until the import UI decides otherwise).
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85.
//  Prior: none (new file).

import Foundation
@testable import M1K3Knowledge
import Testing

struct ConversationKindTests {
    @Test("the raw value is pinned: it persists in knowledge_items.kind")
    func rawValueIsPinned() {
        #expect(KnowledgeKind.conversation.rawValue == "conversation")
    }

    @Test("a conversation is grounded on the document lane, swept at launch, and listed")
    func wiredLikeADocument() {
        #expect(KnowledgeStore.groundingDocumentKinds.contains(.conversation))
        #expect(KnowledgeKind.launchSweepKinds.contains(.conversation))
        #expect(KnowledgeKind.allStaticKinds.contains(.conversation))
        #expect(!KnowledgeKind.hiddenFromRetrieval.contains(.conversation))
        #expect(!KnowledgeKind.withheldFromMCP.contains(.conversation))
        #expect(KnowledgeKind.conversation.displayLabel == "Conversation")
    }

    @Test("a conversation is never donated to Spotlight")
    func neverDonated() {
        let item = KnowledgeItem(kind: .conversation, title: "Planning the hives")
        #expect(SpotlightDonorPolicy.entry(for: item) == nil)
    }

    @Test("a filed conversation comes back from grounding as a citable document-lane hit")
    func retrievedOnTheDocumentLane() async throws {
        let store = try KnowledgeStore()
        let embedder = HashingEmbeddingService()
        try await DocumentIngester(store: store, embedder: embedder).ingest(
            title: "Planning the hives",
            pages: [DocumentPage(pageNumber: 1, text: "User: where should the beehives face\nAssistant: south east")],
            kind: .conversation
        )
        let query = "where should the beehives face"
        let hits = try await store.searchGrounding(
            query: query, queryVector: embedder.embedQuery(query), documentLimit: 5, memoryLimit: 5
        )
        let (knowledge, memories) = GroundingGate.partition(hits, floors: .hashing)
        let hit = try #require(knowledge.first { $0.kind == .conversation })
        #expect(hit.itemTitle == "Planning the hives")
        #expect(memories.isEmpty)
        let cited = CitationFooter.referencedSources(
            from: knowledge, citedBy: [Citation(source: "Planning the hives", heading: "")]
        )
        #expect(cited.map(\.itemID) == [hit.itemID])
    }
}
