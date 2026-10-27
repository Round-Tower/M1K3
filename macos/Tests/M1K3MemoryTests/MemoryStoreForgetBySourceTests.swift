//
//  MemoryStoreForgetBySourceTests.swift
//  M1K3MemoryTests
//
//  #711: an import tags every node it writes with `import/<provider>/<date>`, so "forget
//  everything from this import" is one call. `forget(source:)` is `forget(id:)` applied to every
//  row carrying the tag, so it inherits the consent cascade (row, FTS mirror, vector, every edge)
//  and the undo rule: a row the import superseded is live again afterwards.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85 (pure GRDB, in-memory store; the
//  cascade is forget(id:)'s, pinned again here through the tag).
//  Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-27 (pre-push review fold) — the tag matches EXACTLY (the same provider's
//  import on another day survives), and a chain inside one import (Y ← X ← Z, X and Z tagged) leaves Y live whatever
//  the delete order. Confidence 0.85.

import Foundation
@testable import M1K3Knowledge
@testable import M1K3Memory
import Testing

private let importTag = "import/chatgpt/2026-10-26"

struct MemoryStoreForgetBySourceTests {
    private let embedder = HashingEmbeddingService()

    private func remember(
        _ text: String, source: String, in store: MemoryStore, supersedes oldID: UUID? = nil
    ) async throws -> Memory {
        let memory = Memory(kind: .note, text: text, source: source)
        try await store.remember(memory, embedding: embedder.embed(text), supersedes: oldID)
        return memory
    }

    @Test("forget(source:) removes every tagged row and its residue, and revives what it superseded")
    func cascadeAndRevive() async throws {
        let store = try MemoryStore()
        let oldCity = try await remember("Kev lives in Dublin", source: "distilled", in: store)
        let keep = try await remember("Kev keeps bees", source: "distilled", in: store)
        let first = try await remember("Kev drinks his coffee black", source: importTag, in: store)
        _ = try await remember("Kev plays the fiddle", source: importTag, in: store)
        _ = try await remember("Kev lives in Ardmore", source: importTag, in: store, supersedes: oldCity.id)
        let sibling = try await remember("Kev rows on the Lee", source: "import/chatgpt/2026-10-25", in: store)
        try store.link(MemoryEdge(fromID: first.id, toID: keep.id, relation: "related"))

        #expect(try store.memories(source: importTag).count == 3)
        #expect(try !store.recallFTS(query: "fiddle", limit: 5).isEmpty)
        #expect(try store.memory(id: oldCity.id)?.supersededBy != nil)

        let forgotten = try store.forget(source: importTag)

        #expect(forgotten == 3)
        #expect(try store.memories(source: importTag).isEmpty)
        #expect(try store.totalCount() == 3)
        #expect(try store.embeddingCount() == 3)
        let survivor = try #require(try store.memory(id: sibling.id))
        #expect(survivor.text == sibling.text)
        #expect(survivor.source == "import/chatgpt/2026-10-25")
        #expect(try store.allEdges().isEmpty)
        #expect(try store.recallFTS(query: "fiddle", limit: 5).isEmpty)
        #expect(try store.memory(id: oldCity.id)?.supersededBy == nil)
        let kept = try #require(try store.memory(id: keep.id))
        #expect(kept.text == keep.text && kept.source == "distilled" && kept.supersededBy == nil)
    }

    @Test("a chain inside one import (Y <- X <- Z, X and Z tagged) leaves Y live")
    func chainInsideOneImport() async throws {
        let store = try MemoryStore()
        let y = try await remember("Kev lives in Dublin", source: "distilled", in: store)
        let x = try await remember("Kev lives in Cork", source: importTag, in: store, supersedes: y.id)
        _ = try await remember("Kev lives in Ardmore", source: importTag, in: store, supersedes: x.id)

        #expect(try store.forget(source: importTag) == 2)

        #expect(try store.totalCount() == 1)
        #expect(try store.memory(id: y.id)?.supersededBy == nil)
        #expect(try store.liveCount() == 1)
    }

    @Test("memories(source:) lists the tag's rows newest first, superseded ones included")
    func listsByTag() async throws {
        let store = try MemoryStore()
        let older = Memory(
            kind: .note, text: "Kev rows on the Lee", source: importTag,
            createdAt: Date(timeIntervalSince1970: 1000)
        )
        try await store.remember(older, embedding: embedder.embed(older.text))
        let newer = Memory(
            kind: .note, text: "Kev rows on the Blackwater", source: importTag,
            createdAt: Date(timeIntervalSince1970: 2000)
        )
        try await store.remember(newer, embedding: embedder.embed(newer.text), supersedes: older.id)
        _ = try await remember("Kev keeps bees", source: "distilled", in: store)

        #expect(try store.memories(source: importTag).map(\.id) == [newer.id, older.id])
        #expect(try store.memories(source: "import/claude/2026-10-26").isEmpty)
    }

    @Test("a tag with no rows forgets nothing and touches nothing")
    func unknownTagIsANoOp() async throws {
        let store = try MemoryStore()
        _ = try await remember("Kev keeps bees", source: "distilled", in: store)
        #expect(try store.forget(source: importTag) == 0)
        #expect(try store.totalCount() == 1)
    }
}
