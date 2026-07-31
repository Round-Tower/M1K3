//
//  AdapterSupersedeTests.swift
//  M1K3MemoryChatBridgeTests
//
//  Tier 2 (scratch/dream-cycle/SPEC.md): the adapter's supersede/revive
//  halves of the widened DistilledFactGraphWriting seam, against a REAL
//  in-memory MemoryStore. The seam stays string-typed (fact text is the
//  join key — the same text the dual-write puts in both stores), so
//  M1K3Chat never sees graph UUIDs.
//
//  Source-trust note (spec §1 / B1): the adapter supersedes whatever live
//  node matches — including an `mcp:remember`-sourced one. That is the
//  ALLOWED direction (a distilled/chat fact may supersede an MCP fact);
//  the forbidden direction can't occur because the MCP remember path
//  (`intelligenceRemember`) never calls this seam — it plain-inserts.
//
//  Signed: Kev + claude-fable-5, 2026-07-30, Confidence 0.9. Prior:
//  DistilledFactGraphAdapterTests (Kev + claude-opus-4-8).
//

import Foundation
@testable import M1K3Chat
@testable import M1K3Knowledge
@testable import M1K3Memory
import M1K3MemoryChatBridge
import Testing

private struct Fixture {
    let store: MemoryStore
    let adapter: DistilledFactGraphAdapter
    let embedder = HashingEmbeddingService()

    init() throws {
        store = try MemoryStore()
        adapter = DistilledFactGraphAdapter(store: store)
    }

    func vec(_ text: String) async throws -> [Float] {
        try await embedder.embed(text)
    }
}

struct AdapterSupersedeTests {
    @Test("superseding an existing live fact: old exits recall, new is live")
    func supersedeByText() async throws {
        let f = try Fixture()
        try await f.adapter.writeDistilledFact(
            "Kev lives in Dublin.", kind: .profile,
            embedding: f.vec("Kev lives in Dublin."), superseding: nil
        )
        try await f.adapter.writeDistilledFact(
            "Kev lives in Ardmore.", kind: .profile,
            embedding: f.vec("Kev lives in Ardmore."),
            superseding: "Kev lives in Dublin."
        )

        let hits = try f.store.recall(
            query: "Kev lives Ardmore Dublin",
            queryVector: await f.vec("Kev lives Ardmore Dublin")
        )
        #expect(hits.contains { $0.memory.text == "Kev lives in Ardmore." })
        #expect(!hits.contains { $0.memory.text == "Kev lives in Dublin." })
    }

    @Test("superseding text with no live match degrades to a plain write")
    func supersedeMissDegrades() async throws {
        let f = try Fixture()
        try await f.adapter.writeDistilledFact(
            "Kev lives in Ardmore.", kind: .profile,
            embedding: f.vec("Kev lives in Ardmore."),
            superseding: "Kev lives in Atlantis."
        )
        #expect(try f.store.liveCount() == 1)
    }

    @Test("an mcp:remember-sourced live node CAN be superseded by a distilled fact")
    func distilledSupersedesMCP() async throws {
        let f = try Fixture()
        try f.store.remember(
            Memory(kind: .profile, text: "Kev lives in Dublin.", source: "mcp:remember"),
            embedding: await f.vec("Kev lives in Dublin.")
        )
        try await f.adapter.writeDistilledFact(
            "Kev lives in Ardmore.", kind: .profile,
            embedding: f.vec("Kev lives in Ardmore."),
            superseding: "Kev lives in Dublin."
        )
        #expect(try f.store.liveMemory(matchingText: "Kev lives in Dublin.") == nil)
    }

    @Test("reviveFact supersedes the chain's live head and reports its text")
    func reviveWalksChain() async throws {
        let f = try Fixture()
        try await f.adapter.writeDistilledFact(
            "Kev lives in Dublin.", kind: .profile,
            embedding: f.vec("Kev lives in Dublin."), superseding: nil
        )
        try await f.adapter.writeDistilledFact(
            "Kev lives in Ardmore.", kind: .profile,
            embedding: f.vec("Kev lives in Ardmore."),
            superseding: "Kev lives in Dublin."
        )

        let supplanted = try await f.adapter.reviveFact(
            "Kev lives in Dublin.", kind: .profile,
            embedding: f.vec("Kev lives in Dublin.")
        )

        #expect(supplanted == "Kev lives in Ardmore.")
        let live = try #require(try f.store.liveMemory(matchingText: "Kev lives in Dublin."))
        #expect(live.supersededBy == nil)
        #expect(try f.store.liveMemory(matchingText: "Kev lives in Ardmore.") == nil)
    }

    @Test("a superseding write still earns related edges to live neighbours")
    func supersedeKeepsRelatedEdges() async throws {
        // PR #87 review finding 2: the supersede path bypassed
        // rememberConnected, so corrected facts landed with only a
        // `supersedes` edge — pointing at a node related() can no longer
        // surface — and the Connections panel went empty for them.
        let f = try Fixture()
        // A live topical neighbour sharing tokens with the correction.
        try await f.adapter.writeDistilledFact(
            "Kev lives in Ardmore near the tower.", kind: .note,
            embedding: f.vec("Kev lives in Ardmore near the tower."), superseding: nil
        )
        try await f.adapter.writeDistilledFact(
            "Kev lives in Dublin city.", kind: .profile,
            embedding: f.vec("Kev lives in Dublin city."), superseding: nil
        )

        try await f.adapter.writeDistilledFact(
            "Kev lives in Ardmore village.", kind: .profile,
            embedding: f.vec("Kev lives in Ardmore village."),
            superseding: "Kev lives in Dublin city."
        )

        let corrected = try #require(try f.store.liveMemory(matchingText: "Kev lives in Ardmore village."))
        let neighbours = try f.store.related(to: corrected.id, maxHops: 1)
        #expect(neighbours.contains { $0.text == "Kev lives in Ardmore near the tower." })
    }

    @Test("reviveFact with no superseded match degrades to a plain write, nil supplanted")
    func reviveMissDegrades() async throws {
        let f = try Fixture()
        let supplanted = try await f.adapter.reviveFact(
            "Kev lives in Dublin.", kind: .profile,
            embedding: f.vec("Kev lives in Dublin.")
        )
        #expect(supplanted == nil)
        #expect(try f.store.liveCount() == 1)
    }
}
