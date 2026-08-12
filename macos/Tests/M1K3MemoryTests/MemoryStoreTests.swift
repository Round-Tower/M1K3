//
//  MemoryStoreTests.swift
//  M1K3MemoryTests
//
//  Contract for the temporal memory graph: atomic facts + typed edges +
//  recursive-CTE traversal + supersession-over-time + hard-delete consent.
//  Drives the graduation of scratch/memory-store-sketch into M1K3Memory.
//
//  Embeddings are the deterministic HashingEmbeddingService (bag-of-words FNV),
//  so cosine values are engineerable: identical words → 1.0, disjoint → 0.0,
//  one-of-N shared → 1/√N. That lets the threshold-cutoff tests assert exact
//  inclusion/exclusion rather than hoping a real embedder lands on the right side.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-16, Confidence 0.85 (contract authored
//  test-first to graduate Fable's sketch; cosine engineered for deterministic
//  cutoff assertions). Prior: scratch/memory-store-sketch/MemoryStore.swift
//  (Kev + claude-fable-5).

import Foundation
@testable import M1K3Knowledge
@testable import M1K3Memory
import Testing

private struct Fixture {
    let store: MemoryStore
    let embedder = HashingEmbeddingService()

    init() throws {
        store = try MemoryStore()
    }

    func vec(_ text: String) async throws -> [Float] {
        try await embedder.embed(text)
    }

    /// Store a memory, embedding its own text. Returns the stored value so the
    /// caller has its id for edges/supersession.
    @discardableResult
    func remember(
        _ text: String,
        kind: MemoryKind = .note,
        source: String = "test",
        at date: Date = Date(timeIntervalSince1970: 1_000_000),
        supersedes oldID: UUID? = nil
    ) async throws -> Memory {
        let memory = Memory(kind: kind, text: text, source: source, createdAt: date)
        try store.remember(memory, embedding: await vec(text), supersedes: oldID)
        return memory
    }
}

struct MemoryStoreWriteRecallTests {
    @Test("a remembered fact is recalled by a matching query")
    func rememberThenRecall() async throws {
        let f = try Fixture()
        let m = try await f.remember("Kev's sister is Aoife", kind: .profile)

        let hits = try f.store.recall(query: "Kev sister Aoife", queryVector: await f.vec("Kev sister Aoife"))

        #expect(hits.contains { $0.memory.id == m.id })
        #expect(hits.first?.memory.text == "Kev's sister is Aoife")
    }

    @Test("FTS lane relaxes implicit AND when the strict query zeroes out")
    func recallFTSRelaxesStrictAND() async throws {
        let f = try Fixture()
        try await f.remember("Ada is a scientist")

        // Strict FTS5 (implicit AND) demands every token in one row —
        // "brilliant"/"friend" aren't stored, so the strict pass returns
        // nothing and the OR-joined retry must find the fact (the B5 gap,
        // fixed in KnowledgeStore 9300f574 but not mirrored here until now).
        let hits = try f.store.recallFTS(query: "Ada the brilliant scientist friend", limit: 5)

        #expect(hits.contains { $0.memory.text.contains("Ada") })
    }

    @Test("recall on an empty store returns nothing and does not throw")
    func recallEmpty() async throws {
        let f = try Fixture()
        let hits = try f.store.recall(query: "anything", queryVector: await f.vec("anything"))
        #expect(hits.isEmpty)
    }

    @Test("recall honours the limit")
    func recallLimit() async throws {
        let f = try Fixture()
        for i in 1 ... 5 {
            try await f.remember("alpha beta gamma fact\(i)")
        }
        let hits = try f.store.recall(
            query: "alpha beta gamma", queryVector: await f.vec("alpha beta gamma"), limit: 3
        )
        #expect(hits.count == 3)
    }

    /// ★ Measured on Kev's LIVE store over MCP, 2026-08-12. `recall_memory` gates
    /// on cosine, PRINTS cosine, and then ordered by RRF — so the list was not
    /// sorted by the number it showed you:
    ///
    ///     "what does Kev do for work"
    ///       1. Kev made a decision to use Biomock as a tool for their work.  ~60%
    ///       3. Kev is an engineer by profession with expertise in AI research. ~71%
    ///
    ///     scores in rank order: [60, 63, 71, 70, 45]   ← not monotonic
    ///
    /// The right answer, eleven points better, sat third. Same shape put "Kev is
    /// using a Mac" above three true Cork rows for "where does Kev live" — which
    /// had been read as a floor problem since 2026-08-09. It was never the floor.
    ///
    /// Engineered here with the deterministic hashing embedder: a LONG row
    /// carrying every query token wins the FTS lane outright (strict AND) while
    /// its cosine is diluted by length (k/√(n·m)); a SHORT row shares one token,
    /// misses the strict AND entirely, and scores higher. RRF then ranks the
    /// keyword row first on lane count alone.
    @Test("recall ranks by the similarity it gates on, not by fused rank")
    func recallRanksBySimilarityNotRRF() async throws {
        let f = try Fixture()
        // cosine 2/√(2·8) = 0.5, and the only row FTS's implicit AND accepts.
        try await f.remember("alpha beta gamma delta epsilon zeta eta theta")
        // cosine 1/√(2·1) ≈ 0.707 — better, on one lane only.
        try await f.remember("alpha")

        let hits = try f.store.recall(query: "alpha beta", queryVector: await f.vec("alpha beta"))
        let ordered = hits.map(\.memory.text)
        #expect(ordered.count == 2)
        #expect(ordered.first == "alpha", "the better-scoring row must lead — got \(ordered)")
        // Demoted, never dropped: the keyword lane keeps its seat (see
        // `withKeywordSeat`) — this fix moves the wrong answer DOWN, it does not
        // trade one recall bug for another.
        #expect(ordered.contains("alpha beta gamma delta epsilon zeta eta theta"))
        let scores = hits.map { $0.similarity ?? 0 }
        #expect(scores == scores.sorted(by: >), "not monotonic: \(scores)")
    }

    /// The seat is a guarantee, not a preference: an exact keyword hit whose cosine
    /// is diluted by row length still reaches the user. Pure similarity ranking
    /// would have quietly dropped it off the end of the page — the 2026-07-02
    /// Golden Gate miss arriving by a different door.
    @Test("the keyword lane keeps one seat when similarity alone would drop it")
    func keywordSeatSurvivesBetterScoringRows() throws {
        let store = try MemoryStore()
        let query: [Float] = [1, 0, 0]
        for i in 1 ... 6 {
            try store.remember(
                Memory(kind: .note, text: "banana\(i)", source: "test"), embedding: [1, 0, 0]
            )
        }
        let rare = Memory(kind: .profile, text: "zeta is the answer", source: "test")
        try store.remember(rare, embedding: [0.6, 0.8, 0])

        let hits = try store.recall(query: "zeta", queryVector: query, limit: 2)
        #expect(hits.contains { $0.memory.id == rare.id }, "the only row the user's word names")
        // ...and it takes the LAST seat, so it never displaces a better answer.
        #expect(hits.last?.memory.id == rare.id)
    }

    @Test("a query with punctuation/quotes is sanitised, not crashed")
    func recallSanitisesQuery() async throws {
        let f = try Fixture()
        try await f.remember("alpha beta gamma")
        let hits = try f.store.recall(
            query: "\"alpha\" beta; gamma?", queryVector: await f.vec("alpha beta gamma")
        )
        #expect(!hits.isEmpty)
    }
}

struct MemoryKindCataloguedTests {
    // The catalogued vocabulary is the closed set external surfaces (MCP tools,
    // UIs) may offer; the open string-backed enum stays open for storage. An
    // externally-supplied label parses to a catalogued kind or falls back to
    // .note — a bad label never rejects a fact (the distiller's own doctrine).

    @Test("every catalogued label round-trips")
    func cataloguedLabelsRoundTrip() {
        for kind in MemoryKind.catalogued {
            #expect(MemoryKind(catalogued: kind.rawValue) == kind)
        }
    }

    @Test("unknown, empty, and absent labels fall back to note")
    func unknownFallsBackToNote() {
        #expect(MemoryKind(catalogued: "banana") == .note)
        #expect(MemoryKind(catalogued: "") == .note)
        #expect(MemoryKind(catalogued: nil) == .note)
    }

    @Test("labels are case-insensitive and whitespace-tolerant")
    func labelsNormalized() {
        #expect(MemoryKind(catalogued: "PROFILE") == .profile)
        #expect(MemoryKind(catalogued: " decision ") == .decision)
    }
}

struct MemoryStoreThresholdTests {
    // The GroundingGate.filter lesson applied at source: a keyword-only hit that
    // fails the cosine bar must NOT sneak through recall.
    //
    // Review (2026-07-08, Kev + claude-fable-5): the recall floor moved from
    // chunkThreshold (0.51) to memoryThreshold (0.39) — memories are atomic
    // facts, and query→short-fact cosines sit lower in the cone than
    // query→chunk (the MEMEVAL rationale on GroundingGate.memoryThreshold).
    // The old exclusion case (1/√6 ≈ 0.408) is now the INCLUSION case, and the
    // exclusion contract re-pins at 1/√7 ≈ 0.378 — keyword-only hits below the
    // bar still never sneak through; only the bar itself moved.
    //
    // Review (2026-07-09, Kev + claude-fable-5): memoryThreshold re-derived
    // 0.39 → 0.35 for the query-instruction adoption (instructed MEMEVAL
    // separates cleanly; see GroundingGate). The exclusion contract re-pins
    // one rung further down: 1/√8 ≈ 0.354 is the new inclusion case and
    // 1/√9 ≈ 0.333 the new exclusion — the invariant under test is
    // unchanged (keyword-only hits below the bar never sneak through).

    @Test("an exact-overlap hit clears the cosine bar and is returned")
    func aboveThresholdIncluded() async throws {
        let f = try Fixture()
        let m = try await f.remember("alpha beta gamma") // cosine 1.0 vs same query
        let hits = try f.store.recall(query: "alpha beta gamma", queryVector: await f.vec("alpha beta gamma"))
        #expect(hits.contains { $0.memory.id == m.id })
    }

    @Test("an atomic fact above the memory floor (0.35) but under the chunk bar is recalled")
    func atomicFactAboveMemoryFloorIncluded() async throws {
        let f = try Fixture()
        // Shares exactly ONE token with the query out of eight → cosine = 1/√8 ≈ 0.354:
        // above memoryThreshold (0.35), below chunkThreshold (0.37). This is the
        // identity/keyword class whose live recall-failure drove the 07-08
        // parity fix and the 07-09 instruction adoption.
        let m = try await f.remember("alpha beta gamma delta epsilon zeta eta theta")
        let hits = try f.store.recall(query: "alpha", queryVector: await f.vec("alpha"))
        #expect(hits.contains { $0.memory.id == m.id })
    }

    @Test("a keyword-only hit below the memory floor is excluded")
    func keywordOnlyBelowThresholdExcluded() async throws {
        let f = try Fixture()
        // Shares exactly ONE token with the query out of nine → cosine = 1/√9 ≈ 0.333,
        // under memoryThreshold (0.35). FTS MATCH "alpha" still hits it.
        let m = try await f.remember("alpha beta gamma delta epsilon zeta eta theta iota")
        let hits = try f.store.recall(query: "alpha", queryVector: await f.vec("alpha"))
        #expect(!hits.contains { $0.memory.id == m.id })
    }
}

struct MemoryStoreHybridBackfillTests {
    /// An FTS-lane keyword hit that ranks OUTSIDE the vector top-K must still be
    /// judged on its STORED embedding before the cutoff — not dropped unscored
    /// (the KnowledgeStore.searchHybrid "Golden Gate miss", ported to the graph
    /// lane). Embeddings are passed explicitly so vector rank and FTS rank are
    /// decoupled the way a real embedder makes them; the hashing embedder couples
    /// token overlap across both signals, so a hand-built vector is the clear way
    /// to exercise exactly this "keyword-in, vector-out" seam.
    @Test("a keyword-exact hit outside the vector top-K is scored on its stored embedding, not dropped")
    func ftsOnlyHitJudgedOnStoredEmbedding() throws {
        let store = try MemoryStore()
        let query: [Float] = [1, 0, 0]

        // Six decoys: NO keyword overlap with the query text, but embeddings
        // point straight at the query → they saturate the vector top-K (2·limit).
        for i in 1 ... 6 {
            let decoy = Memory(kind: .note, text: "banana\(i)", source: "test")
            try store.remember(decoy, embedding: [1, 0, 0])
        }
        // Target: FTS-matches "zeta", stored-embedding cosine 0.6 (clears the
        // 0.51 bar) but ranks below every decoy → absent from the vector top-K,
        // so pre-fix its similarity stays nil and the cutoff drops it.
        let target = Memory(kind: .profile, text: "zeta is the answer", source: "test")
        try store.remember(target, embedding: [0.6, 0.8, 0])

        let hits = try store.recall(query: "zeta", queryVector: query, limit: 2)
        #expect(hits.contains { $0.memory.id == target.id })
    }
}

struct MemoryStoreSupersessionTests {
    @Test("a superseded memory drops out of recall; the corrector takes its place")
    func supersededExcludedFromRecall() async throws {
        let f = try Fixture()
        let old = try await f.remember("Kev lives in Dublin", kind: .profile)
        let new = try await f.remember("Kev lives in Cork", kind: .profile, supersedes: old.id)

        let hits = try f.store.recall(query: "where Kev lives", queryVector: await f.vec("Kev lives"))
        #expect(hits.contains { $0.memory.id == new.id })
        #expect(!hits.contains { $0.memory.id == old.id })
    }

    @Test("supersession is correction, not deletion — history is kept")
    func supersededKeptInHistory() async throws {
        let f = try Fixture()
        let old = try await f.remember("Kev lives in Dublin")
        _ = try await f.remember("Kev lives in Cork", supersedes: old.id)

        let live = try f.store.allMemories()
        #expect(!live.contains { $0.id == old.id })

        let withHistory = try f.store.allMemories(includeSuperseded: true)
        #expect(withHistory.contains { $0.id == old.id })
    }

    @Test("supersededMemories returns ONLY corrected rows, newest first, own limit")
    func supersededMemoriesOwnQuery() async throws {
        // The corrected-facts lens must not share a row budget with the live
        // list — a shared LIMIT lets corrected rows displace live ones out of
        // the fetched window (the PR #94 round-2 catch). Own query, own limit.
        let f = try Fixture()
        let oldA = try await f.remember("fact A v1", at: Date(timeIntervalSince1970: 1))
        _ = try await f.remember("fact A v2", at: Date(timeIntervalSince1970: 2), supersedes: oldA.id)
        let oldB = try await f.remember("fact B v1", at: Date(timeIntervalSince1970: 3))
        _ = try await f.remember("fact B v2", at: Date(timeIntervalSince1970: 4), supersedes: oldB.id)

        let corrected = try f.store.supersededMemories()
        #expect(corrected.map(\.id) == [oldB.id, oldA.id]) // newest first
        #expect(corrected.allSatisfy { $0.supersededBy != nil })

        let limited = try f.store.supersededMemories(limit: 1)
        #expect(limited.map(\.id) == [oldB.id])
    }

    @Test("supersession records a typed 'supersedes' edge between the two")
    func supersessionRecordsEdge() async throws {
        let f = try Fixture()
        let old = try await f.remember("first")
        let new = try await f.remember("second", supersedes: old.id)
        // The edge row IS written (lineage keeps the history) …
        let edges = try f.store.allEdges()
        #expect(edges.contains {
            $0.relation == "supersedes" && $0.fromID == new.id && $0.toID == old.id
        })
        // … but traversal no longer surfaces the superseded node (Tier 2,
        // spec finding #7 — the split-visibility fix): related() returns
        // live memories only.
        let neighbours = try f.store.related(to: new.id, maxHops: 1)
        #expect(!neighbours.contains { $0.id == old.id })
    }

    @Test("liveCount counts only non-superseded memories")
    func liveCountExcludesSuperseded() async throws {
        let f = try Fixture()
        let old = try await f.remember("a")
        try await f.remember("b")
        #expect(try f.store.liveCount() == 2)
        _ = try await f.remember("a-corrected", supersedes: old.id)
        #expect(try f.store.liveCount() == 2) // b + a-corrected; old now superseded
    }
}

struct MemoryStoreForgetTests {
    @Test("forget hard-deletes the row and reports it")
    func forgetReturnsTrue() async throws {
        let f = try Fixture()
        let m = try await f.remember("ephemeral")
        #expect(try f.store.forget(id: m.id) == true)
        #expect(try f.store.liveCount() == 0)
    }

    @Test("forgetting an unknown id is a no-op returning false")
    func forgetUnknownFalse() throws {
        let f = try Fixture()
        #expect(try f.store.forget(id: UUID()) == false)
    }

    @Test("forget leaves no residue: gone from recall, graph, and listing")
    func forgetCascades() async throws {
        let f = try Fixture()
        let a = try await f.remember("alpha beta gamma")
        let b = try await f.remember("delta epsilon")
        try f.store.link(MemoryEdge(fromID: a.id, toID: b.id, relation: "about-person"))

        #expect(try f.store.forget(id: a.id) == true)

        let hits = try f.store.recall(query: "alpha beta gamma", queryVector: await f.vec("alpha beta gamma"))
        #expect(!hits.contains { $0.memory.id == a.id })
        #expect(try f.store.allMemories(includeSuperseded: true).allSatisfy { $0.id != a.id })
        // The edge that touched a is gone, so b no longer reaches it.
        #expect(try f.store.related(to: b.id, maxHops: 2).isEmpty)
    }

    @Test("forgetting the corrector revives what it had superseded (undo)")
    func forgetRevivesSuperseded() async throws {
        let f = try Fixture()
        let old = try await f.remember("Kev lives in Dublin")
        let new = try await f.remember("Kev lives in Cork", supersedes: old.id)

        #expect(try f.store.forget(id: new.id) == true)

        let live = try f.store.allMemories()
        #expect(live.contains { $0.id == old.id }) // back among the living
    }
}

struct MemoryStoreGraphTests {
    @Test("link then related returns the one-hop neighbour, undirected")
    func relatedOneHopUndirected() async throws {
        let f = try Fixture()
        let a = try await f.remember("a")
        let b = try await f.remember("b")
        try f.store.link(MemoryEdge(fromID: a.id, toID: b.id, relation: "caused-by"))

        #expect(try f.store.related(to: a.id, maxHops: 1).contains { $0.id == b.id })
        // Edge stored a→b, but traversal is undirected.
        #expect(try f.store.related(to: b.id, maxHops: 1).contains { $0.id == a.id })
    }

    @Test("related respects maxHops — a 2-hop node is unreachable at maxHops 1")
    func relatedMaxHops() async throws {
        let f = try Fixture()
        let a = try await f.remember("a")
        let b = try await f.remember("b")
        let c = try await f.remember("c")
        try f.store.link(MemoryEdge(fromID: a.id, toID: b.id, relation: "part-of"))
        try f.store.link(MemoryEdge(fromID: b.id, toID: c.id, relation: "part-of"))

        let oneHop = try f.store.related(to: a.id, maxHops: 1).map(\.id)
        #expect(oneHop.contains(b.id))
        #expect(!oneHop.contains(c.id))

        let twoHop = try f.store.related(to: a.id, maxHops: 2).map(\.id)
        #expect(twoHop.contains(b.id))
        #expect(twoHop.contains(c.id))
    }

    @Test("allEdges returns every edge, oldest-first")
    func allEdgesBulkRead() async throws {
        let f = try Fixture()
        let a = try await f.remember("a")
        let b = try await f.remember("b")
        let c = try await f.remember("c")
        try f.store.link(MemoryEdge(fromID: a.id, toID: b.id, relation: "first",
                                    createdAt: Date(timeIntervalSince1970: 10)))
        try f.store.link(MemoryEdge(fromID: b.id, toID: c.id, relation: "second",
                                    createdAt: Date(timeIntervalSince1970: 20)))
        let edges = try f.store.allEdges()
        #expect(edges.count == 2)
        #expect(edges.map(\.relation) == ["first", "second"]) // oldest-first
    }

    @Test("related orders nearest hops first and excludes the seed itself")
    func relatedNearestFirstNoSeed() async throws {
        let f = try Fixture()
        let a = try await f.remember("a")
        let b = try await f.remember("b")
        let c = try await f.remember("c")
        try f.store.link(MemoryEdge(fromID: a.id, toID: b.id, relation: "part-of"))
        try f.store.link(MemoryEdge(fromID: b.id, toID: c.id, relation: "part-of"))

        let result = try f.store.related(to: a.id, maxHops: 2).map(\.id)
        #expect(!result.contains(a.id)) // seed excluded
        #expect(try #require(result.firstIndex(of: b.id)) < result.firstIndex(of: c.id)!) // nearest first
    }
}

struct MemoryStoreMaintenanceTests {
    @Test("allMemories returns newest first")
    func allMemoriesNewestFirst() async throws {
        let f = try Fixture()
        try await f.remember("oldest", at: Date(timeIntervalSince1970: 100))
        try await f.remember("newest", at: Date(timeIntervalSince1970: 300))
        try await f.remember("middle", at: Date(timeIntervalSince1970: 200))

        let texts = try f.store.allMemories().map(\.text)
        #expect(texts == ["newest", "middle", "oldest"])
    }

    @Test("the open MemoryKind round-trips through storage")
    func kindRoundTrips() async throws {
        let f = try Fixture()
        let custom = MemoryKind(rawValue: "relationship")
        let m = try await f.remember("Kev and Aoife are siblings", kind: custom)
        let stored = try f.store.allMemories().first { $0.id == m.id }
        #expect(stored?.kind == custom)
    }

    @Test("reindexEmbeddings re-embeds every row and records the fingerprint")
    func reindexEmbeddings() async throws {
        let f = try Fixture()
        try await f.remember("alpha beta gamma")
        try await f.remember("delta epsilon zeta")

        let count = try await f.store.reindexEmbeddings(using: f.embedder, fingerprint: "hashing/v1")
        #expect(count == 2)

        // After re-index, recall still works (vectors intact).
        let hits = try f.store.recall(query: "alpha beta gamma", queryVector: await f.vec("alpha beta gamma"))
        #expect(!hits.isEmpty)
    }

    @Test("memory(id:) fetches by id; unknown id is nil")
    func memoryById() async throws {
        let f = try Fixture()
        let m = try await f.remember("Kev's sister is Aoife", kind: .profile)
        #expect(try f.store.memory(id: m.id)?.text == "Kev's sister is Aoife")
        #expect(try f.store.memory(id: UUID()) == nil)
    }
}

/// Closes the gaps both review gates flagged: the recall path a hit can take
/// through the vector lane alone, graph cycles/self-loops the recursive CTE must
/// survive, and the multi-step supersession chain `forget` only half-unwinds.
struct MemoryStoreReviewGapTests {
    @Test("a vector-only hit (FTS misses on implicit-AND) is still recalled above threshold")
    func vectorOnlyHitRecalled() async throws {
        let f = try Fixture()
        // FTS MATCH ANDs the query tokens, so "alpha" does NOT match the
        // 3-token query. The vector lane still scores it: cosine = 1/√3 ≈ 0.577,
        // over the 0.51 bar → it must come back through backfill, not be lost.
        let m = try await f.remember("alpha")
        let hits = try f.store.recall(query: "alpha beta gamma", queryVector: await f.vec("alpha beta gamma"))
        #expect(hits.contains { $0.memory.id == m.id })
    }

    @Test("recall degrades gracefully on an empty query vector")
    func recallEmptyVector() async throws {
        let f = try Fixture()
        try await f.remember("alpha beta gamma")
        // Mismatched/empty vectors score 0.0 in cosineSimilarity → all fail the
        // cutoff. No crash, just nothing recalled.
        let hits = try f.store.recall(query: "alpha beta gamma", queryVector: [])
        #expect(hits.isEmpty)
    }

    @Test("a cycle returns each node once at its nearest hop")
    func relatedWithCycle() async throws {
        let f = try Fixture()
        let a = try await f.remember("a")
        let b = try await f.remember("b")
        // Both directions of the same pair → a 2-cycle the CTE could re-walk.
        try f.store.link(MemoryEdge(fromID: a.id, toID: b.id, relation: "peer"))
        try f.store.link(MemoryEdge(fromID: b.id, toID: a.id, relation: "peer"))

        let fromA = try f.store.related(to: a.id, maxHops: 3)
        #expect(fromA.filter { $0.id == b.id }.count == 1) // exactly once, no dupes
    }

    @Test("a self-loop edge does not surface the seed or loop forever")
    func relatedWithSelfLoop() async throws {
        let f = try Fixture()
        let a = try await f.remember("a")
        try f.store.link(MemoryEdge(fromID: a.id, toID: a.id, relation: "self"))
        // Only reachable node is the seed, which the outer filter excludes.
        #expect(try f.store.related(to: a.id, maxHops: 3).isEmpty)
    }

    @Test("forget on a supersession chain undoes one step, not the whole chain")
    func forgetMidChainUndoesOneStep() async throws {
        let f = try Fixture()
        let a = try await f.remember("Kev lives in Dublin")
        let b = try await f.remember("Kev lives in Cork", supersedes: a.id)
        let c = try await f.remember("Kev lives in Galway", supersedes: b.id)
        #expect(try f.store.liveCount() == 1) // only c

        #expect(try f.store.forget(id: b.id) == true)

        // Deleting the middle corrector revives its immediate predecessor (a) and
        // leaves the latest (c) live. b is gone. No cascade past one step.
        let liveIDs = try Set(f.store.allMemories().map(\.id))
        #expect(liveIDs == [a.id, c.id])
    }
}

struct MemoryStoreRevisionTests {
    @Test("revision changes when a memory is added")
    func revisionBumpsOnAdd() async throws {
        let f = try Fixture()
        let before = try f.store.revision()
        try await f.remember("a")
        #expect(try f.store.revision() != before)
    }

    @Test("revision changes on supersession even though liveCount is unchanged")
    func revisionCatchesSupersession() async throws {
        let f = try Fixture()
        let old = try await f.remember("a")
        try await f.remember("b")
        let before = try f.store.revision()
        #expect(try f.store.liveCount() == 2)

        // Correction at the SAME timestamp: net liveCount delta is zero, so a
        // count-only signal misses it — the new 'supersedes' edge is what the
        // revision catches (the constellation must redraw on a correction).
        _ = try await f.remember("a-corrected", supersedes: old.id)
        #expect(try f.store.liveCount() == 2) // unchanged
        #expect(try f.store.revision() != before) // but the revision moved
    }

    @Test("revision changes when a memory is forgotten")
    func revisionBumpsOnForget() async throws {
        let f = try Fixture()
        let m = try await f.remember("ephemeral")
        let before = try f.store.revision()
        #expect(try f.store.forget(id: m.id) == true)
        #expect(try f.store.revision() != before)
    }

    @Test("revision changes on a bare link — a new thread with no new mote")
    func revisionCatchesLink() async throws {
        let f = try Fixture()
        let a = try await f.remember("a")
        let b = try await f.remember("b")
        let before = try f.store.revision()
        // No memory written: only the edgeCount arm can catch this (the
        // constellation must draw a new thread even when no node was added).
        try f.store.link(MemoryEdge(fromID: a.id, toID: b.id, relation: "about-person"))
        #expect(try f.store.revision() != before)
    }

    @Test("revision is stable across reads with no writes")
    func revisionStableWhenIdle() async throws {
        let f = try Fixture()
        try await f.remember("a")
        #expect(try f.store.revision() == f.store.revision())
    }
}

// MARK: - Edge-on-write (the graph actually becomes a graph)

struct MemoryStoreConnectedWriteTests {
    @Test("rememberConnected links a new fact to a semantically-similar existing fact")
    func connectsSimilar() async throws {
        let f = try Fixture()
        let a = try await f.remember("alpha beta gamma") // seed node
        let b = Memory(kind: .note, text: "alpha beta gamma delta", source: "test")
        let links = try f.store.rememberConnected(b, embedding: await f.vec(b.text))
        #expect(links == 1)
        #expect(try f.store.related(to: a.id).map(\.id).contains(b.id))
    }

    @Test("rememberConnected leaves an unrelated fact isolated — no hairball")
    func isolatesUnrelated() async throws {
        let f = try Fixture()
        _ = try await f.remember("alpha beta gamma")
        let c = Memory(kind: .note, text: "zeta eta theta", source: "test")
        let links = try f.store.rememberConnected(c, embedding: await f.vec(c.text))
        #expect(links == 0)
        #expect(try f.store.related(to: c.id).isEmpty)
    }

    @Test("rememberConnected caps edges at maxLinks so a common topic can't hairball")
    func capsDegree() async throws {
        let f = try Fixture()
        for i in 1 ... 5 {
            try await f.remember("alpha beta gamma \(i)")
        }
        let n = Memory(kind: .note, text: "alpha beta gamma", source: "test")
        let links = try f.store.rememberConnected(n, embedding: await f.vec(n.text), maxLinks: 3)
        #expect(links == 3)
    }

    @Test("a mid-loop link failure surfaces the partial X/N state through localizedDescription")
    func partialWriteErrorNamesTheDamage() {
        // The catch sites (MemoryDistillationCoordinator, AppEnvironment+Intelligence)
        // breadcrumb `error.localizedDescription` — pin that the wrapped error
        // carries the partial-write state there, not Foundation's generic fallback.
        struct Boom: Error {}
        let id = UUID()
        let error = MemoryGraphPartialWriteError(
            memoryID: id, edgesLinked: 1, edgesPlanned: 3, underlying: Boom()
        )
        #expect(error.localizedDescription.contains("1/3 edges linked"))
        #expect(error.localizedDescription.contains(id.uuidString))
        #expect(error.localizedDescription.contains("node written"))
    }
}
