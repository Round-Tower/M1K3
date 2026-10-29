//
//  HashingMemoryGateTurnTests.swift
//  M1K3KnowledgeTests
//
//  #447 at turn level, through a real KnowledgeStore on the hashing embedder: retrieval
//  (memory top-5), today's floor, then the gate, as AgentRAGResponder runs them. Pairwise
//  scores mislead both ways, so this pins what a turn carries, on two store sizes: a 65-memory
//  store (every fixture memory) and eight 5-memory stores (a first-run user's). Both sides of
//  Kev's override are pinned: the noise the gate removes and the recall it costs. A change to
//  the hashing embedder, the floor, the keyword lane's stopwords or the gate moves these numbers.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-29, Confidence 0.75 (deterministic: hashing and FTS5
//  have no randomness; numbers measured on this run and pinned). Prior: none (new file).
//

import Foundation
@testable import M1K3Knowledge
import Testing

struct HashingMemoryGateTurnTests {
    private let embedder = HashingEmbeddingService()

    private func store(_ facts: [String]) async throws -> KnowledgeStore {
        let store = try KnowledgeStore()
        for fact in facts {
            let item = KnowledgeItem(kind: .memory, title: fact, sourceRef: "t447:\(fact)")
            let chunk = KnowledgeChunk(itemID: item.id, ordinal: 0, heading: nil, content: fact)
            let vector = try await embedder.embed(EmbeddingText.forChunk(title: fact, content: fact))
            try store.index(item: item, chunks: [chunk], embeddings: [vector])
        }
        return store
    }

    /// The memories a turn carries: memory top-5, the floor, then (optionally) the gate.
    private func carried(_ store: KnowledgeStore, _ question: String, gated: Bool) async throws -> [String] {
        let vector = try await embedder.embedQuery(question)
        let retrieved = try store.searchGrounding(query: question, queryVector: vector, memoryLimit: 5)
        let memories = GroundingGate.partition(retrieved, floors: .forFingerprint(embedder.fingerprint)).memories
        let kept = gated
            ? HashingMemoryGate.admitted(memories, question: question, fingerprint: embedder.fingerprint)
            : memories
        return kept.map(\.content)
    }

    struct Tally: Equatable, CustomStringConvertible {
        /// Relevant turns whose own memory reached the prompt.
        var ownReached = 0
        /// Turns (relevant or not) carrying a memory that isn't the question's own.
        var carriesOther = 0
        var turns = 0
        var description: String {
            "own \(ownReached) · other \(carriesOther)/\(turns)"
        }
    }

    private func tally(
        _ pairs: [(memory: String, question: String)], relevant: Bool, store: KnowledgeStore, gated: Bool,
        into tally: inout Tally
    ) async throws {
        for pair in pairs {
            let memories = try await carried(store, pair.question, gated: gated)
            tally.turns += 1
            if relevant, memories.contains(pair.memory) { tally.ownReached += 1 }
            if memories.contains(where: { relevant ? $0 != pair.memory : true }) { tally.carriesOther += 1 }
        }
    }

    @Test("a 65-memory store: the gate removes most unrelated memories and keeps nearly all recall")
    func largeStore() async throws {
        let fixtures = HashingMemoryGateFixtures.self
        let store = try await store(fixtures.positives.map(\.memory) + fixtures.negatives.map(\.memory))
        var today = Tally(), gated = Tally()
        try await tally(fixtures.positives, relevant: true, store: store, gated: false, into: &today)
        try await tally(fixtures.negatives, relevant: false, store: store, gated: false, into: &today)
        try await tally(fixtures.positives, relevant: true, store: store, gated: true, into: &gated)
        try await tally(fixtures.negatives, relevant: false, store: store, gated: true, into: &gated)
        print("65-store today: \(today) · gated: \(gated)")
        // Today every turn carries an unrelated memory, and the floor's collisions crowd the right one
        // out of the top 5 more often than not. Gated: 65 -> 23 noisy turns, recall 17 -> 15.
        #expect(today == Tally(ownReached: 17, carriesOther: 65, turns: 65))
        #expect(gated == Tally(ownReached: 15, carriesOther: 23, turns: 65))
    }

    @Test("eight 5-memory stores (a first-run user's): noise all but gone, recall cost pinned")
    func smallStores() async throws {
        let positives = HashingMemoryGateFixtures.positives
        var today = Tally(), gated = Tally()
        for start in stride(from: 0, to: positives.count, by: 5) {
            let group = Array(positives[start ..< min(start + 5, positives.count)])
            let store = try await store(group.map(\.memory))
            try await tally(group, relevant: true, store: store, gated: false, into: &today)
            try await tally(group, relevant: true, store: store, gated: true, into: &gated)
        }
        print("5-stores today: \(today) · gated: \(gated)")
        // The override's cost, measured: the right memory reaches the prompt 32 -> 19 of 40 (the
        // leap pairs: coeliac x pasta, pregnant x wine), while turns carrying an unrelated memory go
        // 32 -> 1 of 40. Kev's call (2026-10-29): the visible noise matters more than the invisible gap.
        #expect(today == Tally(ownReached: 32, carriesOther: 32, turns: 40))
        #expect(gated == Tally(ownReached: 19, carriesOther: 1, turns: 40))
    }
}
