//
//  HashingKeywordLaneTests.swift
//  M1K3KnowledgeTests
//
//  #670: on the phone's hashing embedder a whole-document chunk never reached the
//  0.35 chunk floor for a keyword question ("roofline" scored 0.084), so "ask your
//  notes" missed on iPhone and iPad. The keyword lane admits ONE document chunk that
//  BM25 matched on every content word of the query, on the hashing arm only. These
//  pins are the challenger's measurement plan: the keyword rows admit the right
//  document, off-domain and chit-chat admit nothing, a relaxed (OR) match never
//  counts, memories are untouched, and a real embedder never reaches the lane.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-23
//  Context: deterministic (hashing + FTS5), so the bars run in CI beside HashingFloorMeasurementTests.
//  Confidence: 0.8 — the bars are pinned; the live Mini turn is verify-by-capture.
//  Format: MurphySig v0.4 (https://murphysig.dev/spec). Prior: none (new file).
//

import Foundation
@testable import M1K3Knowledge
import Testing

struct HashingKeywordLaneTests {
    static let lairTitle = "Lair — planning notes"
    static let lairText = """
    Lair planning notes (the terrace, as its owner insists on calling it).

    Property: a late-Victorian two-storey terrace, south-facing, slate roof. \
    Architect: Niamh Cullen, Cullen & Daly Architects.

    Call, Tuesday. Keep the original roofline. Dormers were discussed and rejected; \
    the conservation officer flagged them at pre-planning. Internal wall insulation \
    to the front elevation only; external wrap to the rear return. Breathable lime \
    plaster throughout. Heat pump: air-to-water, sited in the rear yard, acoustic \
    screen required. Sash windows: refurbish and draught-seal, not replace.

    Actions. Planning drawings to the council by Friday. Get two quotes for the lime \
    plaster. Book the BER assessor for after first fix.
    """
    static let loafTitle = "Weekend loaf — formula"
    static let loafText = """
    Weekend loaf formula, baker's percentages for a single 900 g loaf.

    Strong white flour 90% (450 g). Wholemeal flour 10% (50 g). Water 72% (360 g). \
    Levain at 100% hydration 20% (100 g). Salt 2% (10 g).
    """
    /// The weather-bug class (⌘R): a document that shares a city and a topic word
    /// with chit-chat, so a loose lexical rule would inject it.
    static let corkText = "Moved to Cork in 2019. The bread from the Saturday market is the best in the city."

    private static func store(
        _ docs: [(String, String)], memories: [String] = [], embedder: HashingEmbeddingService = .init()
    ) async throws -> KnowledgeStore {
        let store = try KnowledgeStore()
        let ingester = DocumentIngester(store: store, embedder: embedder)
        for (title, text) in docs {
            try await ingester.ingest(title: title, text: text, sourceRef: "test://\(title)")
        }
        for text in memories {
            let id = UUID()
            try await store.index(
                item: KnowledgeItem(id: id, kind: .memory, title: text, sourceRef: "sha:\(id)"),
                chunks: [KnowledgeChunk(itemID: id, ordinal: 0, content: text)],
                embeddings: embedder.embedBatch([text])
            )
        }
        return store
    }

    private static func admit(_ query: String, in store: KnowledgeStore) throws -> ChunkHit? {
        try HashingKeywordLane.admit(store: store, query: query, fingerprint: HashingEmbeddingService().fingerprint)
    }

    @Test(
        "the issue's keyword rows admit the right document",
        arguments: [
            ("roofline", lairTitle),
            ("dormers", lairTitle),
            ("heat pump", lairTitle),
            ("lair notes roofline", lairTitle),
            ("weekend loaf hydration", loafTitle),
            ("what does the lair say about the roofline?", lairTitle),
        ]
    )
    func keywordRowsAdmit(query: String, title: String) async throws {
        let store = try await Self.store([(Self.lairTitle, Self.lairText), (Self.loafTitle, Self.loafText)])
        let hit = try Self.admit(query, in: store)
        #expect(hit?.itemTitle == title)
    }

    @Test(
        "chit-chat and the weather class admit nothing, even beside a Cork document",
        arguments: [
            "what's the weather in Cork", "yo what's up", "what model are you", "tell me a joke",
            "what is it?", "how are you today?", "", "   ",
        ]
    )
    func chitChatAdmitsNothing(query: String) async throws {
        let store = try await Self.store([
            ("Cork", Self.corkText), (Self.lairTitle, Self.lairText), (Self.loafTitle, Self.loafText),
        ])
        #expect(try Self.admit(query, in: store) == nil)
    }

    @Test("the ABSEP off-domain pairs admit nothing")
    func offDomainAdmitsNothing() async throws {
        for pair in SeparationEvalFixtures.offDomain {
            let store = try await Self.store([("doc", pair.document)])
            #expect(try Self.admit(pair.query, in: store) == nil, "\(pair.query)")
        }
    }

    @Test("a relaxed (OR) match never counts: every content word must be in the chunk")
    func relaxedNeverAdmits() async throws {
        let store = try await Self.store([(Self.lairTitle, Self.lairText)])
        // "roofline" is in the notes; "gutters" is not. The OR retry would match.
        #expect(try store.searchFTS(query: "roofline gutters").isEmpty == false, "the relaxed retry does match")
        #expect(try Self.admit("roofline gutters", in: store) == nil)
    }

    @Test("a real embedder never reaches the lane")
    func onlyTheHashingArm() async throws {
        let store = try await Self.store([(Self.lairTitle, Self.lairText)])
        for fingerprint in ["embeddinggemma-2/mrl512", "qwen3-embed-512", ""] {
            #expect(try HashingKeywordLane.admit(store: store, query: "roofline", fingerprint: fingerprint) == nil)
        }
    }

    @Test("memories are never admitted: the memory lane keeps its own floor")
    func memoriesUntouched() async throws {
        let store = try await Self.store([], memories: ["Keeps the original roofline on the lair."])
        #expect(try Self.admit("roofline", in: store) == nil)
    }

    @Test("excluded kinds stay excluded")
    func excludedKinds() async throws {
        let store = try await Self.store([(Self.lairTitle, Self.lairText)])
        let hit = try HashingKeywordLane.admit(
            store: store, query: "roofline", fingerprint: HashingEmbeddingService().fingerprint,
            excludedKinds: [.document]
        )
        #expect(hit == nil)
    }

    @Test("GroundedSearch admits one keyword chunk on the hashing arm, and only when the cosine lane kept no document")
    func groundedSearchUsesTheLane() async throws {
        let embedder = HashingEmbeddingService()
        let store = try await Self.store([(Self.lairTitle, Self.lairText), (Self.loafTitle, Self.loafText)])
        let hits = try await GroundedSearch.run(store: store, embedder: embedder, query: "roofline", limit: 5)
        #expect(hits.map(\.itemTitle) == [Self.lairTitle])
        // Chit-chat still grounds on nothing.
        #expect(try await GroundedSearch.run(store: store, embedder: embedder, query: "tell me a joke", limit: 5).isEmpty)
    }

    @Test("content terms drop stopwords, punctuation and case; nil when nothing is left")
    func contentTerms() {
        #expect(HashingKeywordLane.contentTerms("What did the architect say about the Roofline?") == ["architect", "roofline"])
        #expect(HashingKeywordLane.contentTerms("what’s up?") == nil)
        #expect(HashingKeywordLane.contentTerms("") == nil)
        #expect(HashingKeywordLane.contentTerms("heat-pump") == ["heat", "pump"])
    }
}
