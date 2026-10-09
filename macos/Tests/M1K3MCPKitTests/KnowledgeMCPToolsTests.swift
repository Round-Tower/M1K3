//
//  KnowledgeMCPToolsTests.swift
//  M1K3MCPKitTests
//
//  The MCP tool handlers over a real in-memory store. The stdio transport is
//  glue; this is where the behaviour Claude will see is pinned.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-fable-5, 2026-07-02 — search is async + optionally
//  hybrid (GroundedSearch); added the embedder-injected hybrid + gated
//  abstention pins. FTS-only surface unchanged via the nil default.
//  Review: Kev + claude-opus-5-5, 2026-09-27 — #378: empty query and bad/unknown ids now pin a
//  throw, the quarantine case included. Confidence 0.85.

import Foundation
import M1K3Knowledge
@testable import M1K3MCPKit
import Testing

private func seededStore() async throws -> KnowledgeStore {
    let store = try KnowledgeStore()
    let ingester = DocumentIngester(store: store, embedder: HashingEmbeddingService())
    try await ingester.ingest(
        title: "Plant Notes",
        text: "3.2 Seals\nThe hydraulic seal on the conveyor failed under load."
    )
    try await ingester.ingest(
        title: "Safety",
        text: "4.1 PPE\nOperators must wear gloves near the press."
    )
    return store
}

struct KnowledgeMCPToolsTests {
    @Test("a Photo caption never reaches an MCP client: not listed, not searched, not fetched")
    func photoCaptionsAreWithheld() async throws {
        let store = try await seededStore()
        let result = try await ImageCaptionIngester(store: store, embedder: HashingEmbeddingService())
            .ingest(caption: "A whiteboard listing the hydraulic pricing tiers.", attachmentFilename: "P.jpg")
        let tools = KnowledgeMCPTools(store: store)
        #expect(try !tools.listDocuments().contains("whiteboard"))
        #expect(try !tools.listDocuments().contains(result.itemID.uuidString))
        let found = try await tools.searchKnowledge(query: "hydraulic", limit: 10)
        #expect(!found.contains("pricing tiers"))
        #expect(found.contains("Plant Notes"))
        let refusal = #expect(throws: MCPInputError.self) {
            try tools.getDocument(idString: result.itemID.uuidString)
        }
        #expect(refusal?.description.contains("No document found") == true)
    }

    @Test("get_document by id treats a quarantined item as not found")
    func getDocumentQuarantinedHidden() async throws {
        let store = try await seededStore()
        // Quarantined items are excluded from list/search, so their ids never
        // surface organically — but the by-id path must not be the back door:
        // a known UUID renders NOTHING, indistinguishable from absent.
        let quarantinedID = UUID()
        let text = "Internal QA triage: canary honeypot lives here."
        try store.index(
            item: KnowledgeItem(id: quarantinedID, kind: .quarantined, title: "Internal QA"),
            chunks: [KnowledgeChunk(itemID: quarantinedID, ordinal: 0, content: text)],
            embeddings: await HashingEmbeddingService().embedBatch([text])
        )
        let tools = KnowledgeMCPTools(store: store)
        // Refused exactly as an absent id is (#378: as an error), naming nothing inside.
        let refusal = #expect(throws: MCPInputError.self) {
            try tools.getDocument(idString: quarantinedID.uuidString)
        }
        let out = refusal?.description ?? ""
        #expect(out.contains("No document found"))
        #expect(!out.contains("canary"))
        #expect(!out.contains("Internal QA"))
    }

    @Test("search_knowledge returns ranked matching chunks")
    func search() async throws {
        let tools = try await KnowledgeMCPTools(store: seededStore())
        let out = try await tools.searchKnowledge(query: "hydraulic seal", limit: 5)
        #expect(out.contains("Plant Notes"))
        #expect(out.contains("hydraulic seal"))
    }

    @Test("search_knowledge refuses an empty query (#378: as an error) and reports no matches")
    func searchEdges() async throws {
        let tools = try await KnowledgeMCPTools(store: seededStore())
        await #expect(throws: MCPInputError.self) { try await tools.searchKnowledge(query: "   ") }
        #expect(try await tools.searchKnowledge(query: "zzzznotpresent").contains("No results"))
    }

    @Test("search_knowledge runs gated hybrid when the host injects an embedder")
    func searchHybrid() async throws {
        // Same embedder the seeding ingester used → same vector space; an
        // exact-sentence query earns cosine ≈ 1.0, well past the floor.
        let tools = try await KnowledgeMCPTools(
            store: seededStore(), embedder: HashingEmbeddingService()
        )
        let out = try await tools.searchKnowledge(
            query: "The hydraulic seal on the conveyor failed under load.", limit: 5
        )
        #expect(out.contains("Plant Notes"))
        #expect(out.contains("hydraulic seal"))
    }

    @Test("search_knowledge abstains honestly when nothing clears the floor")
    func searchHybridAbstains() async throws {
        let tools = try await KnowledgeMCPTools(
            store: seededStore(), embedder: HashingEmbeddingService()
        )
        // Off-store gibberish: cosine ~0 everywhere, FTS empty — the gated
        // path must say the store doesn't cover it, not "No results" (the
        // FTS-only phrasing) and never top-K garbage.
        let out = try await tools.searchKnowledge(query: "zzzznotpresent gibberish", limit: 5)
        #expect(out.contains("don't cover this"))
    }

    @Test("list_documents lists every indexed item with its id")
    func list() async throws {
        let store = try await seededStore()
        let tools = KnowledgeMCPTools(store: store)
        let out = try tools.listDocuments()
        #expect(out.contains("Plant Notes"))
        #expect(out.contains("Safety"))
        // ids present so get_document can be called.
        let firstID = try #require(store.allItems().first?.id.uuidString)
        #expect(out.contains(firstID))
    }

    @Test("get_document returns the full text by id, and errors cleanly")
    func get() async throws {
        let store = try await seededStore()
        let tools = KnowledgeMCPTools(store: store)
        let id = try #require(store.allItems().first { $0.title == "Plant Notes" }?.id)
        let out = try tools.getDocument(idString: id.uuidString)
        #expect(out.contains("# Plant Notes"))
        #expect(out.contains("hydraulic seal"))

        #expect(throws: MCPInputError.self) { try tools.getDocument(idString: "not-a-uuid") }
        #expect(throws: MCPInputError.self) { try tools.getDocument(idString: UUID().uuidString) }
    }

    @Test("get_document on a title-only item explains the empty body instead of a bare header")
    func getEmptyBody() async throws {
        let store = try await seededStore()
        // A chunkless item — how McCulloch-Pitts got in: indexed, listed, no
        // extractable text (test-report F3).
        let item = KnowledgeItem(kind: .document, title: "Title Only Doc")
        try store.index(item: item, chunks: [])
        let tools = KnowledgeMCPTools(store: store)
        let out = try tools.getDocument(idString: item.id.uuidString)
        #expect(out.contains("# Title Only Doc"))
        #expect(out.lowercased().contains("title only"))
        #expect(out.lowercased().contains("no readable text"))
    }

    @Test("get_document caps long output and points at the resume offset")
    func getPaged() async throws {
        let store = try await seededStore()
        // Body (chunk content) is 1000 chars: 500 A's then 500 B's. Offsets are
        // into the body, not the rendered header.
        let big = String(repeating: "A", count: 500) + String(repeating: "B", count: 500)
        let item = KnowledgeItem(kind: .document, title: "Big Doc")
        let chunk = KnowledgeChunk(itemID: item.id, ordinal: 0, heading: nil, content: big)
        try store.index(item: item, chunks: [chunk])
        let tools = KnowledgeMCPTools(store: store)

        // First page: first 400 chars (all A's), with a resume footer at offset 400.
        let page1 = try tools.getDocument(idString: item.id.uuidString, maxChars: 400)
        #expect(page1.contains("# Big Doc"))
        #expect(page1.contains("600 more characters"))
        #expect(page1.contains("offset:400"))
        #expect(!page1.contains("BBBBB")) // the B tail hasn't been reached yet

        // Resuming at offset 400 reaches the B tail and ends cleanly.
        let page2 = try tools.getDocument(idString: item.id.uuidString, maxChars: 600, offset: 400)
        #expect(page2.contains("BBBBB"))
        #expect(page2.contains("end of document"))
        #expect(!page2.contains("more characters"))
    }

    @Test("resolveStorePath honours the env override")
    func storePathOverride() {
        let path = resolveStorePath(environment: ["M1K3_STORE_PATH": "/tmp/custom.sqlite"])
        #expect(path == "/tmp/custom.sqlite")
    }
}
