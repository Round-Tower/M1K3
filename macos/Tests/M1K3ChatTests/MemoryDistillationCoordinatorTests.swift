//
//  MemoryDistillationCoordinatorTests.swift
//  M1K3ChatTests
//
//  Facts → memory items, with both dedupe layers: exact (normalized-hash
//  sourceRef — DocumentIngester's existing no-op-on-existing-sourceRef) and
//  semantic (embedding similarity against stored memories). The semantic
//  layer is exercised with identical strings under the hashing embedder
//  (cosine 1.0) — true paraphrase-dedupe is MLX-verified at ⌘R; these tests
//  prove the mechanism.
//
//  Signed: Kev + claude-fable-5, 2026-06-12, Confidence 0.9, Prior: Unknown

import Foundation
@testable import M1K3Chat
@testable import M1K3Knowledge
import Testing

private struct FakeDistiller: MemoryDistilling {
    let result: Result<[DistilledFact], Error>

    /// Most tests only care about texts — untyped facts land as `.note`,
    /// exactly like a bare "FACT:" line from a model.
    init(result: Result<[String], Error>) {
        self.result = result.map { $0.map { DistilledFact(text: $0) } }
    }

    init(typed: [DistilledFact]) {
        result = .success(typed)
    }

    func distill(turns _: [ChatTurn]) async throws -> [DistilledFact] {
        try result.get()
    }
}

private struct Boom: Error {}

/// Records every graph dual-write so a test can assert WHICH distilled facts
/// reached the graph (and with which kind + embedding). Optionally throws to
/// prove the dual-write is best-effort.
private actor FakeGraphWriter: DistilledFactGraphWriting {
    private(set) var writes: [(text: String, kind: DistilledFactKind, embedding: [Float])] = []
    let shouldThrow: Bool
    init(shouldThrow: Bool = false) {
        self.shouldThrow = shouldThrow
    }

    func writeDistilledFact(
        _ text: String, kind: DistilledFactKind, embedding: [Float], superseding _: String?
    ) async throws {
        if shouldThrow { throw Boom() }
        writes.append((text, kind, embedding))
    }

    func reviveFact(_ text: String, kind: DistilledFactKind, embedding: [Float]) async throws -> String? {
        if shouldThrow { throw Boom() }
        writes.append((text, kind, embedding))
        return nil
    }

    func texts() -> [String] {
        writes.map(\.text)
    }

    func kinds() -> [DistilledFactKind] {
        writes.map(\.kind)
    }
}

private func makeFixture(
    facts: Result<[String], Error>,
    graph: (any DistilledFactGraphWriting)? = nil
) throws -> (MemoryDistillationCoordinator, KnowledgeStore) {
    let store = try KnowledgeStore()
    let embedder = HashingEmbeddingService()
    return (
        MemoryDistillationCoordinator(
            distiller: FakeDistiller(result: facts),
            ingester: DocumentIngester(store: store, embedder: embedder),
            store: store,
            embedder: embedder,
            graph: graph
        ),
        store
    )
}

private let someTurns = [
    ChatTurn(role: .user, text: "My sister is called Aoife"),
    ChatTurn(role: .assistant, text: "Noted!"),
]

struct MemoryDistillationCoordinatorTests {
    @Test("N facts land as N memory items with distilled provenance")
    func factsBecomeMemories() async throws {
        let (coordinator, store) = try makeFixture(facts: .success([
            "Kev's sister is called Aoife.",
            "The user prefers metric units.",
        ]))
        let written = try await coordinator.distillAndStore(turns: someTurns)
        #expect(written == 2)
        let memories = try store.allItems(kind: .memory)
        #expect(memories.count == 2)
        #expect(memories.allSatisfy { $0.source == .distilled })
        // Facts are searchable — the residency loop covers distilled memory.
        #expect(try store.searchFTS(query: "Aoife").isEmpty == false)
    }

    @Test("a long fact gets a word-boundary title, full text as content")
    func longFactTitleCut() async throws {
        let fact = "The user decided that the memory architecture should live inside the existing knowledge store rather than a separate database."
        let (coordinator, store) = try makeFixture(facts: .success([fact]))
        _ = try await coordinator.distillAndStore(turns: someTurns)
        let memory = try #require(try store.allItems(kind: .memory).first)
        #expect(memory.title.count <= 60)
        // Cut on a word boundary — no mid-word chop.
        #expect(fact.hasPrefix(memory.title.replacingOccurrences(of: "…", with: "")))
        let chunks = try store.chunks(forItem: memory.id)
        #expect(chunks.first?.content == fact)
    }

    @Test("the same fact distilled twice collapses to one row (exact layer)")
    func exactDedupe() async throws {
        let (coordinator, store) = try makeFixture(facts: .success(["Kev lives in Cork."]))
        let first = try await coordinator.distillAndStore(turns: someTurns)
        let second = try await coordinator.distillAndStore(turns: someTurns)
        #expect(first == 1)
        #expect(second == 0)
        #expect(try store.allItems(kind: .memory).count == 1)
    }

    @Test("normalization variants collapse too — case and punctuation don't make new rows")
    func normalizedDedupe() async throws {
        let (first, store) = try makeFixture(facts: .success(["Kev lives in Cork."]))
        _ = try await first.distillAndStore(turns: someTurns)
        // Same store, new coordinator emitting a case/punct variant.
        let variantCoordinator = MemoryDistillationCoordinator(
            distiller: FakeDistiller(result: .success(["kev lives in cork"])),
            ingester: DocumentIngester(store: store, embedder: HashingEmbeddingService()),
            store: store,
            embedder: HashingEmbeddingService()
        )
        let written = try await variantCoordinator.distillAndStore(turns: someTurns)
        #expect(written == 0)
        #expect(try store.allItems(kind: .memory).count == 1)
    }

    @Test("semantic layer: a near-identical stored memory is superseded — one live row, the newer text")
    func semanticSupersede() async throws {
        // Seed a memory whose NORMALIZED form differs (extra word) so the
        // exact layer misses, but whose embedding clears the bar. Tier 2:
        // the twin is superseded (never the new fact eaten) — retrieval
        // still holds exactly one row, and it is the newer assertion.
        let (seeder, store) = try makeFixture(facts: .success(["Kev lives in Cork city Ireland today"]))
        _ = try await seeder.distillAndStore(turns: someTurns)
        let nearCoordinator = MemoryDistillationCoordinator(
            distiller: FakeDistiller(result: .success(["Kev lives in Cork city Ireland"])),
            ingester: DocumentIngester(store: store, embedder: HashingEmbeddingService()),
            store: store,
            embedder: HashingEmbeddingService()
        )
        _ = try await nearCoordinator.distillAndStore(turns: someTurns)
        let live = try store.allItems(kind: .memory)
        #expect(live.count == 1)
        #expect(live.first?.title == "Kev lives in Cork city Ireland")
        #expect(try store.allItems(kind: .memorySuperseded).count == 1)
    }

    @Test("a throwing distiller rethrows — the caller keeps the watermark")
    func distillerThrowRethrows() async throws {
        let (coordinator, _) = try makeFixture(facts: .failure(Boom()))
        await #expect(throws: (any Error).self) {
            try await coordinator.distillAndStore(turns: someTurns)
        }
    }

    @Test("zero facts writes nothing and returns 0")
    func zeroFactsNoWrites() async throws {
        let (coordinator, store) = try makeFixture(facts: .success([]))
        let written = try await coordinator.distillAndStore(turns: someTurns)
        #expect(written == 0)
        #expect(try store.itemCount() == 0)
    }

    // MARK: - Dual-write to the graph (the missing seam)

    @Test("a newly distilled fact is written to BOTH the corpus and the graph")
    func newFactDualWrites() async throws {
        let graph = FakeGraphWriter()
        let (coordinator, store) = try makeFixture(
            facts: .success(["Kev's sister is called Aoife.", "The user prefers metric units."]),
            graph: graph
        )
        let written = try await coordinator.distillAndStore(turns: someTurns)
        #expect(written == 2)
        #expect(try store.allItems(kind: .memory).count == 2) // corpus
        let graphed = await graph.texts() // graph
        #expect(Set(graphed) == ["Kev's sister is called Aoife.", "The user prefers metric units."])
        #expect(await graph.writes.allSatisfy { !$0.embedding.isEmpty })
    }

    @Test("the distiller's classification rides the dual-write into the graph")
    func kindReachesGraph() async throws {
        let graph = FakeGraphWriter()
        let store = try KnowledgeStore()
        let embedder = HashingEmbeddingService()
        let coordinator = MemoryDistillationCoordinator(
            distiller: FakeDistiller(typed: [
                DistilledFact(text: "Kev's sister is called Aoife.", kind: .profile),
                DistilledFact(text: "The user prefers metric units.", kind: .preference),
            ]),
            ingester: DocumentIngester(store: store, embedder: embedder),
            store: store,
            embedder: embedder,
            graph: graph
        )
        _ = try await coordinator.distillAndStore(turns: someTurns)
        #expect(await graph.kinds() == [.profile, .preference])
    }

    @Test("a deduped fact is NOT written to the graph (dedup is respected on the seam)")
    func dedupedFactSkipsGraph() async throws {
        let graph = FakeGraphWriter()
        // First pass writes it to corpus + graph; second pass is an exact dup.
        let (first, store) = try makeFixture(facts: .success(["Kev lives in Cork."]), graph: graph)
        _ = try await first.distillAndStore(turns: someTurns)
        let second = MemoryDistillationCoordinator(
            distiller: FakeDistiller(result: .success(["Kev lives in Cork."])),
            ingester: DocumentIngester(store: store, embedder: HashingEmbeddingService()),
            store: store,
            embedder: HashingEmbeddingService(),
            graph: graph
        )
        _ = try await second.distillAndStore(turns: someTurns)
        #expect(await graph.texts() == ["Kev lives in Cork."]) // graphed once, not twice
        #expect(try store.allItems(kind: .memory).count == 1)
    }

    @Test("a graph-write failure does not fail distillation — the corpus write stands")
    func graphFailureIsBestEffort() async throws {
        let graph = FakeGraphWriter(shouldThrow: true)
        let (coordinator, store) = try makeFixture(facts: .success(["Kev lives in Cork."]), graph: graph)
        let written = try await coordinator.distillAndStore(turns: someTurns)
        #expect(written == 1)
        #expect(try store.allItems(kind: .memory).count == 1)
    }
}
