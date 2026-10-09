//
//  DocumentToolsTests.swift
//  M1K3KnowledgeToolsTests
//
//  ListDocumentsTool + GetDocumentTool over a real store.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-10-09 (#523 second-pass fold) — `excludedKinds` pins: the MCP
//  palette's list/get never list or fetch a Photo (title match included); the local default still does.

import Foundation
import M1K3Knowledge
@testable import M1K3KnowledgeTools
import Testing

private func seededStore() throws -> KnowledgeStore {
    let store = try KnowledgeStore()
    let doc = UUID()
    try store.index(
        item: KnowledgeItem(id: doc, kind: .document, title: "Plant Notes"),
        chunks: [
            KnowledgeChunk(itemID: doc, ordinal: 0, content: "The hydraulic seal failed."),
            KnowledgeChunk(itemID: doc, ordinal: 1, content: "Replace before next shift."),
        ],
        embeddings: nil
    )
    let call = UUID()
    try store.index(
        item: KnowledgeItem(id: call, kind: .call, title: "Vendor call"),
        chunks: [KnowledgeChunk(itemID: call, ordinal: 0, content: "Discussed delivery dates.")],
        embeddings: nil
    )
    return store
}

/// The seeded store plus one Photo whose title (the caption's head) matches "whiteboard".
private func storeWithPhoto() async throws -> KnowledgeStore {
    let store = try seededStore()
    try await ImageCaptionIngester(store: store)
        .ingest(caption: "A whiteboard listing the hydraulic pricing tiers.", attachmentFilename: "W.jpg")
    return store
}

struct DocumentToolsExclusionTests {
    @Test("list_documents with excludedKinds never lists a Photo; the local default still does")
    func listWithholdsPhotos() async throws {
        let store = try await storeWithPhoto()
        let withheld = try await ListDocumentsTool(store: store, excludedKinds: KnowledgeKind.withheldFromMCP)
            .execute(input: [:]).output
        #expect(!withheld.contains("whiteboard"))
        #expect(!withheld.contains("[image]"))
        #expect(withheld.contains("Plant Notes [document]"))
        let local = try await ListDocumentsTool(store: store).execute(input: [:]).output
        #expect(local.contains("A whiteboard listing the hydraulic pricing tiers. [image]"))
    }

    @Test("list_documents on a store holding only Photos reads as empty to the MCP palette")
    func listPhotoOnlyStoreIsEmpty() async throws {
        let store = try KnowledgeStore()
        try await ImageCaptionIngester(store: store)
            .ingest(caption: "A photo of a whiteboard.", attachmentFilename: "W.jpg")
        let out = try await ListDocumentsTool(store: store, excludedKinds: KnowledgeKind.withheldFromMCP)
            .execute(input: [:]).output
        #expect(out.contains("No stored knowledge"))
    }

    @Test("get_document with excludedKinds never fetches a Photo by title match; the local default still does")
    func getWithholdsPhotos() async throws {
        let store = try await storeWithPhoto()
        let withheld = try await GetDocumentTool(store: store, excludedKinds: KnowledgeKind.withheldFromMCP)
            .execute(input: ["title": "whiteboard"]).output
        #expect(withheld.contains("No document matching"))
        #expect(!withheld.contains("pricing tiers"))
        // The excluded Photo must not shadow a real document either.
        let doc = try await GetDocumentTool(store: store, excludedKinds: KnowledgeKind.withheldFromMCP)
            .execute(input: ["title": "plant"]).output
        #expect(doc.contains("hydraulic seal failed"))
        let local = try await GetDocumentTool(store: store).execute(input: ["title": "whiteboard"]).output
        #expect(local.contains("pricing tiers"))
    }
}

struct ListDocumentsToolTests {
    @Test("lists every stored item with its kind")
    func lists() async throws {
        let tool = try ListDocumentsTool(store: seededStore())
        let out = try await tool.execute(input: [:]).output
        #expect(out.contains("Plant Notes [document]"))
        #expect(out.contains("Vendor call [call]"))
    }

    @Test("reports an empty store cleanly")
    func empty() async throws {
        let tool = try ListDocumentsTool(store: KnowledgeStore())
        #expect(try await tool.execute(input: [:]).output.contains("No stored knowledge"))
    }
}

struct GetDocumentToolTests {
    @Test("wire schema requires title only — offset is optional (115 review nit)")
    func offsetIsOptionalOnTheWire() throws {
        let definition = try GetDocumentTool(store: KnowledgeStore()).toolDefinition
        let required = definition.parameters.filter(\.isRequired).map(\.name)
        #expect(required == ["title"])
    }

    @Test("fetches a document's full text by partial title")
    func fetches() async throws {
        let tool = try GetDocumentTool(store: seededStore())
        let out = try await tool.execute(input: ["title": "plant"]).output
        #expect(out.contains("# Plant Notes"))
        #expect(out.contains("hydraulic seal failed"))
        #expect(out.contains("Replace before next shift"))
    }

    @Test("reports when no document matches")
    func noMatch() async throws {
        let tool = try GetDocumentTool(store: seededStore())
        #expect(try await tool.execute(input: ["title": "spaceship"]).output.contains("No document matching"))
    }

    @Test("empty title is an error")
    func emptyTitle() async throws {
        let tool = try GetDocumentTool(store: seededStore())
        #expect(try await tool.execute(input: ["title": " "]).output.hasPrefix("Error:"))
    }

    @Test("pages very long documents with a resume-offset footer")
    func pagesLongDocuments() async throws {
        let store = try KnowledgeStore()
        let id = UUID()
        let big = String(repeating: "A", count: 150) + String(repeating: "B", count: 150)
        try store.index(
            item: KnowledgeItem(id: id, kind: .document, title: "Big"),
            chunks: [KnowledgeChunk(itemID: id, ordinal: 0, content: big)],
            embeddings: nil
        )
        let tool = GetDocumentTool(store: store, maxChars: 100)

        // First page: capped, with the exact resume offset — never a silent cut.
        let page1 = try await tool.execute(input: ["title": "Big"]).output
        #expect(page1.contains("200 more characters"))
        #expect(page1.contains("offset:100"))
        #expect(!page1.contains("BBBBB"))

        // Resuming reaches the tail and says so.
        let page2 = try await tool.execute(input: ["title": "Big", "offset": "200"]).output
        #expect(page2.contains("BBBBB"))
        #expect(page2.contains("end of document"))
    }

    @Test("explains a title-only item instead of returning a bare header")
    func chunklessItem() async throws {
        let store = try KnowledgeStore()
        try store.index(
            item: KnowledgeItem(kind: .document, title: "Title Only Doc"),
            chunks: []
        )
        let tool = GetDocumentTool(store: store)
        let out = try await tool.execute(input: ["title": "Title Only"]).output
        #expect(out.contains("# Title Only Doc"))
        #expect(out.lowercased().contains("no readable text"))
    }
}
