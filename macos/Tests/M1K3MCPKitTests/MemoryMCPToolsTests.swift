//
//  MemoryMCPToolsTests.swift
//  M1K3MCPKitTests
//
//  The memory-graph MCP tools over a REAL in-memory MemoryStore + a fake
//  embedder. The handlers are injected closures (the IntelligenceMCPTools
//  pattern); here we wire them to an actual MemoryStore so the recall/related
//  formatting + the honest empty-state messages are pinned against the store
//  Claude will really hit.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-16, Confidence 0.85 (handlers pinned
//  against a real store + a deterministic embedder; live embedder/path wiring
//  is app glue, verify-at-⌘R). Prior: IntelligenceMCPToolsTests (this file).
//

import Foundation
import M1K3Knowledge // HashingEmbeddingService, EmbeddingService
@testable import M1K3MCPKit
import M1K3Memory
import MCP
import Testing

private func text(_ result: CallTool.Result) -> String? {
    if case let .text(text, _, _) = result.content.first { return text }
    return nil
}

/// Wire MemoryToolHandlers to a real in-memory store + a deterministic
/// embedder, the way MCPHostController will (minus the MainActor glue).
private func makeHandlers(
    store: MemoryStore,
    embedder: any EmbeddingService
) -> MemoryToolHandlers {
    MemoryToolHandlers(
        recall: { query in
            let vector = try await embedder.embed(query)
            return try store.recall(query: query, queryVector: vector)
        },
        related: { query in
            let vector = try await embedder.embed(query)
            guard let seed = try store.recall(query: query, queryVector: vector, limit: 1).first else {
                return nil
            }
            let neighbours = try store.related(to: seed.memory.id)
            return (seed.memory, neighbours)
        },
        stats: {
            let live = try store.liveCount()
            return MemoryStatsSummary(liveCount: live)
        },
        forget: { query in
            // Mirror the app glue minus the corpus twin: recall, resolve against
            // the forget floor, hard-delete on a confident match.
            let vector = try await embedder.embed(query)
            let hits = try store.recall(query: query, queryVector: vector, limit: 12)
            switch ForgetResolver.resolve(hits: hits, query: query) {
            case let .forget(memory):
                try store.forget(id: memory.id)
                return .forgotten(text: memory.text)
            case let .notConfident(closest):
                return .notConfident(closest: closest?.text)
            }
        }
    )
}

/// Seed a store with two linked facts (so related() has an edge to traverse)
/// plus an unrelated one. Embeds each fact with the same fake embedder.
private func seededStore(embedder: any EmbeddingService) async throws -> (MemoryStore, UUID, UUID) {
    let store = try MemoryStore()
    let sister = Memory(kind: .profile, text: "Kev's sister is Aoife.", source: "test")
    let birthday = Memory(kind: .profile, text: "Aoife's birthday is in March.", source: "test")
    let unrelated = Memory(kind: .note, text: "The conveyor belt runs at 3 metres per second.", source: "test")
    try store.remember(sister, embedding: await embedder.embed(sister.text))
    try store.remember(birthday, embedding: await embedder.embed(birthday.text))
    try store.remember(unrelated, embedding: await embedder.embed(unrelated.text))
    // Connect the two profile facts so related() returns a neighbour.
    try store.link(MemoryEdge(fromID: sister.id, toID: birthday.id, relation: "about-person"))
    return (store, sister.id, birthday.id)
}

struct MemoryMCPToolsTests {
    @Test("the surface is recall_memory, related_memory, memory_stats, forget_memory")
    func surface() throws {
        let embedder = HashingEmbeddingService()
        let store = try MemoryStore()
        let registry = MCPToolRegistry(makeMemoryToolDefinitions(handlers: makeHandlers(store: store, embedder: embedder)))
        #expect(registry.tools.map(\.name) == ["recall_memory", "related_memory", "memory_stats", "forget_memory"])
    }

    @Test("recall_memory returns matching facts with a similarity hint")
    func recallHit() async throws {
        let embedder = HashingEmbeddingService()
        let (store, _, _) = try await seededStore(embedder: embedder)
        let registry = MCPToolRegistry(makeMemoryToolDefinitions(handlers: makeHandlers(store: store, embedder: embedder)))
        let result = await registry.call(name: "recall_memory", arguments: ["query": .string("Kev's sister Aoife")])
        #expect(result.isError != true)
        let out = try #require(text(result))
        #expect(out.contains("Aoife"))
        // a similarity hint is surfaced (percentage form)
        #expect(out.contains("%"))
    }

    @Test("recall_memory says so honestly when nothing clears the bar")
    func recallEmpty() async throws {
        let embedder = HashingEmbeddingService()
        let store = try MemoryStore() // empty
        let registry = MCPToolRegistry(makeMemoryToolDefinitions(handlers: makeHandlers(store: store, embedder: embedder)))
        let result = await registry.call(name: "recall_memory", arguments: ["query": .string("anything at all")])
        #expect(result.isError != true)
        #expect(text(result)?.lowercased().contains("nothing") == true)
    }

    @Test("recall_memory with a blank query is an isError")
    func recallBlank() async throws {
        let embedder = HashingEmbeddingService()
        let store = try MemoryStore()
        let registry = MCPToolRegistry(makeMemoryToolDefinitions(handlers: makeHandlers(store: store, embedder: embedder)))
        let result = await registry.call(name: "recall_memory", arguments: ["query": .string("   ")])
        #expect(result.isError == true)
    }

    @Test("related_memory surfaces the seed fact and its graph neighbours")
    func relatedHit() async throws {
        let embedder = HashingEmbeddingService()
        let (store, _, _) = try await seededStore(embedder: embedder)
        let registry = MCPToolRegistry(makeMemoryToolDefinitions(handlers: makeHandlers(store: store, embedder: embedder)))
        let result = await registry.call(name: "related_memory", arguments: ["query": .string("Kev's sister Aoife")])
        #expect(result.isError != true)
        let out = try #require(text(result))
        // the seed (sister) AND the linked neighbour (birthday) both appear
        #expect(out.contains("sister is Aoife"))
        #expect(out.contains("birthday"))
    }

    @Test("related_memory says so when there is no seed to anchor from")
    func relatedNoSeed() async throws {
        let embedder = HashingEmbeddingService()
        let store = try MemoryStore() // empty → no seed
        let registry = MCPToolRegistry(makeMemoryToolDefinitions(handlers: makeHandlers(store: store, embedder: embedder)))
        let result = await registry.call(name: "related_memory", arguments: ["query": .string("Aoife")])
        #expect(result.isError != true)
        #expect(text(result)?.lowercased().contains("nothing") == true)
    }

    @Test("memory_stats reports the live count")
    func stats() async throws {
        let embedder = HashingEmbeddingService()
        let (store, _, _) = try await seededStore(embedder: embedder)
        let registry = MCPToolRegistry(makeMemoryToolDefinitions(handlers: makeHandlers(store: store, embedder: embedder)))
        let result = await registry.call(name: "memory_stats", arguments: nil)
        #expect(result.isError != true)
        let out = try #require(text(result))
        #expect(out.contains("3")) // three seeded live memories
    }

    @Test("forget_memory hard-deletes a confident match and says what went")
    func forgetConfident() async throws {
        let embedder = HashingEmbeddingService()
        let (store, _, _) = try await seededStore(embedder: embedder)
        let registry = MCPToolRegistry(makeMemoryToolDefinitions(handlers: makeHandlers(store: store, embedder: embedder)))
        let result = await registry.call(name: "forget_memory", arguments: ["query": .string("Kev's sister is Aoife.")])
        #expect(result.isError != true)
        let out = try #require(text(result))
        #expect(out.lowercased().contains("forgotten"))
        #expect(out.contains("Aoife"))
        // the fact is actually gone from the live store
        #expect(try store.liveCount() == 2)
    }

    @Test("forget_memory deletes nothing when nothing is a confident match")
    func forgetNotConfident() async throws {
        let embedder = HashingEmbeddingService()
        let (store, _, _) = try await seededStore(embedder: embedder)
        let registry = MCPToolRegistry(makeMemoryToolDefinitions(handlers: makeHandlers(store: store, embedder: embedder)))
        let result = await registry.call(
            name: "forget_memory",
            arguments: ["query": .string("the orbital mechanics of Jupiter's moons")]
        )
        #expect(result.isError != true)
        // nothing erased — all three seeded memories survive
        #expect(try store.liveCount() == 3)
    }

    @Test("forget_memory with a blank query is an isError")
    func forgetBlank() async throws {
        let embedder = HashingEmbeddingService()
        let store = try MemoryStore()
        let registry = MCPToolRegistry(makeMemoryToolDefinitions(handlers: makeHandlers(store: store, embedder: embedder)))
        let result = await registry.call(name: "forget_memory", arguments: ["query": .string("   ")])
        #expect(result.isError == true)
    }
}
