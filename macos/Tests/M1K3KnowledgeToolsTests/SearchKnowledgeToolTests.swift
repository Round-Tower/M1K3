//
//  SearchKnowledgeToolTests.swift
//  M1K3KnowledgeToolsTests
//
//  Integration of the whole pure stack: ingest into a real KnowledgeStore →
//  the LocalAgent emits ACTION: search_knowledge(...) → the tool runs FTS →
//  the agent concludes from the real observation. Plus direct tool unit tests.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-10-09 (code-quality fold) — excludedKinds pin (caption memory).

import Foundation
import M1K3Agent
import M1K3Inference
import M1K3Knowledge
@testable import M1K3KnowledgeTools
import Synchronization
import Testing

// MARK: - Scripted provider (mirrors the agent test double)

private final class ScriptedProvider: InferenceProvider, @unchecked Sendable {
    let name = "scripted"
    let isAvailable = true
    private let lock = NSLock()
    private var responses: [String]
    private var index = 0
    init(_ responses: [String]) {
        self.responses = responses
    }

    func generate(prompt _: String) async throws -> String {
        lock.withLock {
            defer { index += 1 }
            return index < responses.count ? responses[index] : "CONCLUSION: (fallback)"
        }
    }

    func generateStreaming(prompt _: String) -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }
}

// MARK: - Scripted embedder (exact cosine control for the relevance floor)

/// Maps known strings to fixed unit vectors so tests choose each hit's cosine
/// similarity precisely; unknown strings embed to a zero vector (cosine 0).
private struct ScriptedEmbedder: EmbeddingService {
    let dimension = 2
    let fingerprint = "test/scripted/1"
    let vectors: [String: [Float]]

    func embed(_ text: String) async throws -> [Float] {
        vectors[text] ?? [0, 0]
    }

    func isAvailable() async -> Bool {
        true
    }
}

// MARK: - Fixture

private func storeWithNotes() throws -> KnowledgeStore {
    let store = try KnowledgeStore()
    let id = UUID()
    let item = KnowledgeItem(id: id, kind: .document, title: "Plant Notes")
    let chunks = [
        KnowledgeChunk(itemID: id, ordinal: 0, heading: "3.2 Seals", content: "The hydraulic seal on the conveyor failed under load."),
        KnowledgeChunk(itemID: id, ordinal: 1, heading: "4.1 Safety", content: "Operators must wear gloves near the press."),
    ]
    try store.index(item: item, chunks: chunks, embeddings: nil)
    return store
}

// MARK: - Tests

struct SearchKnowledgeToolExclusionTests {
    @Test("excludedKinds keeps a Photo caption out of the tool's observation; the default still finds it")
    func excludedKindsHidePhotos() async throws {
        let store = try storeWithNotes()
        try await ImageCaptionIngester(store: store)
            .ingest(caption: "A whiteboard listing the hydraulic pricing tiers.", attachmentFilename: "W.jpg")
        let withheld = try await SearchKnowledgeTool(store: store, excludedKinds: KnowledgeKind.withheldFromMCP)
            .execute(input: ["query": "hydraulic"])
        #expect(!withheld.output.contains("pricing tiers"))
        #expect(withheld.output.contains("conveyor"))
        let local = try await SearchKnowledgeTool(store: store).execute(input: ["query": "hydraulic"])
        #expect(local.output.contains("pricing tiers"))
    }
}

struct SearchKnowledgeToolTests {
    @Test("returns matching chunks formatted with title and heading")
    func returnsMatches() async throws {
        let tool = try SearchKnowledgeTool(store: storeWithNotes())
        let result = try await tool.execute(input: ["query": "hydraulic"])
        #expect(result.output.contains("Plant Notes"))
        #expect(result.output.contains("§3.2 Seals"))
        #expect(result.output.contains("failed under load"))
    }

    @Test("reports no results cleanly")
    func noResults() async throws {
        let tool = try SearchKnowledgeTool(store: storeWithNotes())
        let result = try await tool.execute(input: ["query": "spaceship"])
        #expect(result.output.contains("No results"))
    }

    @Test("empty query is an error observation")
    func emptyQuery() async throws {
        let tool = try SearchKnowledgeTool(store: storeWithNotes())
        let result = try await tool.execute(input: ["query": "   "])
        #expect(result.output.hasPrefix("Error:"))
    }

    @Test("respects the result limit")
    func respectsLimit() async throws {
        let store = try KnowledgeStore()
        let id = UUID()
        let chunks = (0 ..< 5).map {
            KnowledgeChunk(itemID: id, ordinal: $0, content: "seal report number \($0)")
        }
        try store.index(item: KnowledgeItem(id: id, kind: .note, title: "Reports"), chunks: chunks, embeddings: nil)
        let tool = SearchKnowledgeTool(store: store, limit: 2)
        let result = try await tool.execute(input: ["query": "seal"])
        // Two numbered lines only.
        #expect(result.output.split(separator: "\n").count == 2)
    }

    @Test("with an embedder the search is hybrid, floored, and kept hits reach the collector")
    func hybridWithCollector() async throws {
        let store = try KnowledgeStore()
        let sealContent = "The hydraulic seal on the conveyor failed under load."
        let gloveContent = "Operators must wear gloves near the press."
        let embedder = ScriptedEmbedder(vectors: [
            "hydraulic seal": [1, 0],
            sealContent: [1, 0], // cosine 1.0 — relevant
            gloveContent: [0, 1], // cosine 0.0 — nearest-neighbour noise
        ])
        let id = UUID()
        let chunks = [
            KnowledgeChunk(itemID: id, ordinal: 0, heading: "3.2 Seals", content: sealContent),
            KnowledgeChunk(itemID: id, ordinal: 1, heading: "4.1 Safety", content: gloveContent),
        ]
        let embeddings = try await embedder.embedBatch(chunks.map(\.content))
        try store.index(
            item: KnowledgeItem(id: id, kind: .document, title: "Plant Notes"),
            chunks: chunks,
            embeddings: embeddings
        )

        let collected = Mutex<[ChunkHit]>([])
        let tool = SearchKnowledgeTool(
            store: store,
            embedder: embedder,
            onHits: { hits in collected.withLock { $0.append(contentsOf: hits) } }
        )
        let result = try await tool.execute(input: ["query": "hydraulic seal"])

        #expect(result.output.contains("Plant Notes"))
        #expect(result.output.contains("§3.2 Seals"))
        // The orthogonal chunk rode the vector top-K but fails the floor —
        // it must not reach the model or the citation allow-list.
        #expect(!result.output.contains("gloves"))
        let hits = collected.withLock { $0 }
        #expect(hits.map(\.heading) == ["3.2 Seals"])
    }

    @Test("when nothing clears the floor the tool abstains instead of returning top-K garbage")
    func irrelevantHitsAbstain() async throws {
        let store = try KnowledgeStore()
        let content = "The hydraulic seal on the conveyor failed under load."
        let embedder = ScriptedEmbedder(vectors: [
            "my configuration": [0, 1],
            content: [1, 0], // cosine 0 vs the query — pure nearest-neighbour
        ])
        let id = UUID()
        let chunks = [KnowledgeChunk(itemID: id, ordinal: 0, content: content)]
        try store.index(
            item: KnowledgeItem(id: id, kind: .document, title: "Plant Notes"),
            chunks: chunks,
            embeddings: await embedder.embedBatch(chunks.map(\.content))
        )

        let collected = Mutex<[ChunkHit]>([])
        let tool = SearchKnowledgeTool(
            store: store,
            embedder: embedder,
            onHits: { hits in collected.withLock { $0.append(contentsOf: hits) } }
        )
        let result = try await tool.execute(input: ["query": "my configuration"])

        #expect(result.output.contains("Nothing relevant"))
        #expect(!result.output.contains("hydraulic"))
        #expect(collected.withLock { $0 }.isEmpty)
    }

    @Test("a memory clears its lower bar where a document at the same cosine is dropped")
    func memoryClearsLowerBar() async throws {
        let store = try KnowledgeStore()
        // Unit vector at cosine 0.36 to [1,0]: between memoryThreshold (0.35)
        // and chunkThreshold (0.37) after the 2026-07-09 instructed-query
        // re-derivation (the inter-bar band narrowed with the re-tune).
        let band: [Float] = [0.36, 0.933]
        let memoryContent = "Kev's sister is called Aoife."
        let docContent = "Quarterly throughput rose by four percent."
        let embedder = ScriptedEmbedder(vectors: [
            "sister name": [1, 0],
            memoryContent: band,
            docContent: band,
        ])

        let memoryID = UUID()
        let memoryChunks = [KnowledgeChunk(itemID: memoryID, ordinal: 0, content: memoryContent)]
        try store.index(
            item: KnowledgeItem(id: memoryID, kind: .memory, title: "Kev's sister"),
            chunks: memoryChunks,
            embeddings: await embedder.embedBatch(memoryChunks.map(\.content))
        )
        let docID = UUID()
        let docChunks = [KnowledgeChunk(itemID: docID, ordinal: 0, content: docContent)]
        try store.index(
            item: KnowledgeItem(id: docID, kind: .document, title: "Plant Notes"),
            chunks: docChunks,
            embeddings: await embedder.embedBatch(docChunks.map(\.content))
        )

        let tool = SearchKnowledgeTool(store: store, embedder: embedder)
        let result = try await tool.execute(input: ["query": "sister name"])

        #expect(result.output.contains("Aoife"))
        #expect(!result.output.contains("throughput"))
    }

    @Test("a relevant memory surfaces even when documents fill the result limit (two-lane budget)")
    func memoryNotCrowdedOutByDocuments() async throws {
        let store = try KnowledgeStore()
        // Query word appears in NO content, so FTS contributes nothing and the
        // vector cosine deterministically orders the lanes.
        let query = "who is lila"
        let doc1 = "Project alpha shipped in Q1."
        let doc2 = "Project beta shipped in Q2."
        let doc3 = "Project gamma shipped in Q3."
        let memory = "Ada is a marine biologist."
        let embedder = ScriptedEmbedder(vectors: [
            query: [1, 0],
            doc1: [0.95, 0.312], // every document out-scores the memory…
            doc2: [0.93, 0.367],
            doc3: [0.91, 0.414],
            memory: [0.6, 0.8], // …but the memory still clears both bars (cosine 0.6)
        ])

        let docID = UUID()
        let docChunks = [doc1, doc2, doc3].enumerated().map {
            KnowledgeChunk(itemID: docID, ordinal: $0.offset, content: $0.element)
        }
        try store.index(
            item: KnowledgeItem(id: docID, kind: .document, title: "Projects"),
            chunks: docChunks,
            embeddings: await embedder.embedBatch(docChunks.map(\.content))
        )
        let memID = UUID()
        let memChunks = [KnowledgeChunk(itemID: memID, ordinal: 0, content: memory)]
        try store.index(
            item: KnowledgeItem(id: memID, kind: .memory, title: "Ada"),
            chunks: memChunks,
            embeddings: await embedder.embedBatch(memChunks.map(\.content))
        )

        // limit 2 < the 3 documents: a single-lane top-K would be ALL documents and
        // the memory would never appear. The two-lane budget gives memories their own
        // slots — this is the search_knowledge "Ada gap" the chat path didn't have.
        let tool = SearchKnowledgeTool(store: store, embedder: embedder, limit: 2)
        let result = try await tool.execute(input: ["query": query])
        #expect(result.output.contains("marine biologist"))
    }

    @Test("an FTS-only hit (no vector score) does not survive the hybrid floor")
    func ftsOnlyDroppedInHybrid() async throws {
        let store = try KnowledgeStore()
        let id = UUID()
        let chunks = [KnowledgeChunk(itemID: id, ordinal: 0, content: "hydraulic seal failed")]
        // Indexed WITHOUT embeddings: any hit is keyword-only, never vector-scored.
        try store.index(
            item: KnowledgeItem(id: id, kind: .document, title: "Plant Notes"),
            chunks: chunks,
            embeddings: nil
        )

        let tool = SearchKnowledgeTool(
            store: store,
            embedder: ScriptedEmbedder(vectors: ["hydraulic": [1, 0]])
        )
        let result = try await tool.execute(input: ["query": "hydraulic"])
        #expect(result.output.contains("Nothing relevant"))
    }

    @Test("a no-result search reports nothing to the collector")
    func noResultsNothingCollected() async throws {
        let collected = Mutex<[ChunkHit]>([])
        let tool = try SearchKnowledgeTool(
            store: storeWithNotes(),
            onHits: { hits in collected.withLock { $0.append(contentsOf: hits) } }
        )
        _ = try await tool.execute(input: ["query": "spaceship"])
        #expect(collected.withLock { $0 }.isEmpty)
    }

    @Test("END TO END: agent searches the real store and concludes from it")
    func agentEndToEnd() async throws {
        let store = try storeWithNotes()
        let tool = SearchKnowledgeTool(store: store)
        // The agent decides to search, gets the real observation, then concludes.
        let provider = ScriptedProvider([
            "I should check the notes. ACTION: search_knowledge(hydraulic seal)",
            "CONCLUSION: The hydraulic seal failed under load.",
        ])
        let agent = LocalAgent(inferenceProvider: provider, tools: [tool])
        let result = try await agent.run(goal: "What failed on the conveyor?")

        #expect(result.toolsUsed == ["search_knowledge"])
        #expect(result.conclusion == "The hydraulic seal failed under load.")
        // The observation in the trace is the REAL store content, not a mock.
        #expect(result.reasoningTrace[0].observation?.contains("failed under load") == true)
    }
}
