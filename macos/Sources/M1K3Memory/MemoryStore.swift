//
//  MemoryStore.swift
//  M1K3Memory
//
//  Memory as a first-class store, SEPARATE from the RAG document corpus.
//  Today `remember` ingests through DocumentIngester into KnowledgeStore —
//  i.e. a memory IS a document. This store splits them, because the two have
//  different physics:
//
//    RAG docs (KnowledgeStore)          Memories (this store)
//    ─────────────────────────          ─────────────────────
//    big, chunked, immutable            small, atomic, single-row
//    ingested wholesale                 written one fact at a time
//    deleted per-document               deleted per-fact (consent surface)
//    no relations between chunks        edges between memories matter
//    cited via § tokens                 surfaced as "you told me…"
//    relevance is the only signal       recency + supersession also signal
//
//  This is the temporal memory GRAPH: atomic facts (nodes) + typed edges +
//  supersession-over-time, traversed by a recursive CTE. It is the artifact a
//  later persona/"knows-me" LoRA distils — facts stay here (queryable, editable,
//  deletable), the *shape* of how they relate over time is what a prior learns.
//
//  DESIGN DECISIONS (vs the generic advice):
//
//  1. NO sqlite-vec, NO extension loading, NO SQLCipher build change.
//     The house pattern (KnowledgeStore.swift) is already BLOB embedding
//     columns + brute-force cosine in Swift + RRF hybrid — proven on-device,
//     zero dependencies, and fine to ~10k rows. A lifetime of atomic personal
//     memories is thousands of rows, not millions. Revisit only if recall
//     latency shows up in TTFT logs.
//
//  2. NO graph database. Edges are a table; traversal is a recursive CTE,
//     which SQLite runs natively and GRDB passes through untouched.
//
//  3. Memories are SINGLE-ROW — no chunking. A memory is an atomic fact
//     ("Kev's sister is Aoife", "decided RRF over learned fusion on 06-11").
//     If text arrives too big to be one fact, that's an ingest-policy problem
//     (summarise or split at write time), not a storage problem. This is what
//     makes per-row deletion an honest consent surface.
//
//  4. Same EmbedderReindexPolicy doctrine as KnowledgeStore: vectors carry an
//     embedder fingerprint in a meta table; kernel bump → one-time re-index.
//
//  5. Retrieval cutoff: reuse GroundingGate.memoryThreshold (0.35 since the
//     2026-07-09 instructed-query re-derivation; 0.39 before) — memories
//     are atomic facts, and query→short-fact cosines sit lower in the cone
//     than query→chunk (the MEMEVAL rationale on that constant). Was
//     chunkThreshold (0.51) until 2026-07-08; the stricter chunk bar silently
//     dropped the identity-fact class the corpus memory lane already recalls.
//     FTS-only hits still must NOT bypass the bar when recall is implicit —
//     the exact leak GroundingGate.filter fixed; only the bar moved.
//     NOTE (07-09 title composition): only the VECTOR lane gets the B5
//     title rescue — memory_fts indexes fact text alone (matching
//     knowledge_chunk_fts, which never indexes item titles either), so a
//     keyword whose only match is the title rides the vector lane.
//
//  6. SEPARATE DATABASE FILE (memory.sqlite), not new tables in knowledge.db.
//     Different lifecycle (sync/export/forget-all), different consent story,
//     and CloudKit row-wise sync later wants a clean record boundary.
//
//  iOS NOTE: this file works unchanged on iOS — GRDB, FTS5, recursive CTEs,
//  BLOB cosine all ship in the system SQLite. The only platform delta is where
//  embeddings come from and the Data Protection class on the file.
//
//  ── Review ───────────────────────────────────────────────────────────────
//  Graduated from scratch/memory-store-sketch into a real, tested target. The
//  design is Fable's; this pass added the test contract (M1K3MemoryTests) that
//  pins recall-cutoff, supersession-over-time, undirected traversal, and the
//  forget consent cascade, and wired the M1K3Memory target into Package.swift.
//  Logic is unchanged from the sketch except where a test demanded a guarantee
//  the sketch only implied. The duplicated `sanitizeFTSQuery` is carried as a
//  documented follow-up: lift it (and KnowledgeStore's twin) into one shared
//  home in M1K3Knowledge rather than widen this feature PR's blast radius.
//  Signed: Kev + claude-opus-4-8, 2026-06-16, Confidence 0.88 (idioms proven in
//  KnowledgeStore; graph + supersession now TDD'd green; live remember-path
//  migration deliberately deferred to its own PR). Prior: Kev + claude-fable-5
//  (scratch/memory-store-sketch/MemoryStore.swift) → Kev + claude-opus-4-8
//  (KnowledgeStore.swift).
//  Review: Kev + claude-fable-5, 2026-07-02 — executed the documented follow-up:
//  the duplicated sanitiser is lifted into M1K3Knowledge.FTSQuery (shared with
//  KnowledgeStore), and recallFTS gained the strict→relaxed zero-hit retry (B5)
//  its twin already had. The cosine floor in `recall` still gates relaxed hits.

import Foundation
import GRDB
import M1K3Knowledge // VectorMath, ReciprocalRankFusion, GroundingGate, EmbeddingService

/// A `rememberConnected` link-loop failure AFTER the node was written: the
/// node is live (and its corpus vector makes the distiller's semantic dedup
/// skip any retry), but only `edgesLinked` of `edgesPlanned` edges landed.
/// Carries the partial state so caller breadcrumbs can say exactly that
/// instead of a misleading "skipped" (112 review nit).
public struct MemoryGraphPartialWriteError: Error, CustomStringConvertible, LocalizedError {
    public let memoryID: UUID
    public let edgesLinked: Int
    public let edgesPlanned: Int
    public let underlying: Error

    public var description: String {
        "graph partial-write: \(edgesLinked)/\(edgesPlanned) edges linked for "
            + "\(memoryID.uuidString) — node written, retry is dedup-masked: \(underlying)"
    }

    /// The catch sites breadcrumb `error.localizedDescription` — without this
    /// they'd log the generic Foundation fallback and lose the X/N state.
    public var errorDescription: String? {
        description
    }
}

// MARK: - Domain model

/// What kind of fact this is. Open string-backed enum, same pattern as
/// KnowledgeKind — new kinds need no schema change.
public struct MemoryKind: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// A fact about the user ("sister is Aoife"). Feeds the persona About-block.
    public static let profile = MemoryKind(rawValue: "profile")
    /// A standing preference ("prefers en-GB spellings", "no emoji in commits").
    public static let preference = MemoryKind(rawValue: "preference")
    /// A decision + rationale ("RRF over learned fusion, 06-11, because…").
    public static let decision = MemoryKind(rawValue: "decision")
    /// An event that happened ("shipped Gecko companion on 06-11").
    public static let episode = MemoryKind(rawValue: "episode")
    /// Anything else worth keeping.
    public static let note = MemoryKind(rawValue: "note")
    // Both write paths classify as of 2026-07-08: the distiller via
    // DistilledFactKind (M1K3Chat, mapped across the bridge) and the explicit
    // MCP `remember` tool via an agent-supplied catalogued label.

    /// The catalogued vocabulary — the closed set external surfaces (MCP tools,
    /// UIs) may offer. The enum itself stays open for storage/migration; this
    /// is what gets advertised.
    ///
    /// Vocabulary cross-reference — adding a kind means also updating
    /// `DistilledFactKind` + the distiller prompt prose (M1K3Chat/
    /// MemoryDistiller.swift) and the MCP `remember` description prose
    /// (M1K3MCPKit/IntelligenceMCPTools.swift); the schema enum and bridge
    /// mapping derive from this list automatically.
    public static let catalogued: [MemoryKind] = [.profile, .preference, .decision, .episode, .note]

    /// Parse an externally-supplied kind label: a catalogued match
    /// (case-insensitive, trimmed) or `.note`. A bad label misclassifies,
    /// it never rejects a fact — the same doctrine as the distiller's parser.
    public init(catalogued raw: String?) {
        let label = raw?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        self = Self.catalogued.first { $0.rawValue == label } ?? .note
    }
}

/// One atomic memory. Small, deletable, supersedable.
/// `Hashable` (synthesised — every field is Hashable) so the app can drive
/// value-based SwiftUI navigation (`navigationDestination(for: Memory.self)`).
public struct Memory: Identifiable, Equatable, Hashable, Sendable, Codable {
    public var id: UUID
    public var kind: MemoryKind
    /// The fact itself. Atomic — one idea per row. Soft cap at write time
    /// (~500 chars); bigger inputs should be split/summarised by the caller.
    public var text: String
    /// Optional discriminating context (B5 layer 3, ported to the graph lane
    /// 2026-07-09): an MCP `remember` carries a user title whose context the
    /// bare fact text may lack ("Golden Gate milestone — …"), and the vector
    /// embeds COMPOSED via `embeddingText` so keyword queries can find long
    /// facts. Distilled facts are their own titles → nil, embeds bare.
    public var title: String?
    /// Who/what wrote it: "mcp:remember", "chat:auto-distill", "user:settings".
    /// The provenance half of the consent story — Settings can show it.
    public var source: String
    public var createdAt: Date
    /// Set when a newer memory replaces this one. Superseded rows are kept
    /// (history, undo) but excluded from recall by default. Forgetting is
    /// still hard-delete — supersession is correction, not deletion.
    public var supersededBy: UUID?

    public init(
        id: UUID = UUID(),
        kind: MemoryKind,
        text: String,
        title: String? = nil,
        source: String,
        createdAt: Date = Date(),
        supersededBy: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.title = title
        self.source = source
        self.createdAt = createdAt
        self.supersededBy = supersededBy
    }

    /// The text this memory's vector is derived from: title-prefixed through
    /// the SAME `EmbeddingText.forChunk` rules the corpus lane uses (empty/nil
    /// title or content leading with the title → bare). Every writer and the
    /// reindex MUST embed this, never `text` — mixed composition in one store
    /// compares incompatible vectors.
    public var embeddingText: String {
        EmbeddingText.forChunk(title: title ?? "", content: text)
    }
}

/// A typed, directed relation between two memories.
/// The "graph" is this table + recursive CTEs — nothing more.
public struct MemoryEdge: Equatable, Sendable, Codable {
    public var fromID: UUID
    public var toID: UUID
    /// Open vocabulary: "supersedes", "about-person", "caused-by", "part-of".
    public var relation: String
    public var createdAt: Date

    public init(fromID: UUID, toID: UUID, relation: String, createdAt: Date = Date()) {
        self.fromID = fromID
        self.toID = toID
        self.relation = relation
        self.createdAt = createdAt
    }
}

/// A cheap, pollable change-signature of the store. Equatable so a UI (the
/// constellation) can gate a relayout on "did anything change?" without
/// re-reading every row each tick.
public struct MemoryRevision: Equatable, Sendable {
    public let memoryCount: Int
    public let edgeCount: Int
    public let latestCreatedAt: Double

    public init(memoryCount: Int, edgeCount: Int, latestCreatedAt: Double) {
        self.memoryCount = memoryCount
        self.edgeCount = edgeCount
        self.latestCreatedAt = latestCreatedAt
    }
}

/// A recall result: the memory plus how it scored.
public struct MemoryHit: Identifiable, Equatable, Sendable {
    public var id: UUID {
        memory.id
    }

    public var memory: Memory
    public var similarity: Float?
    public var rrfScore: Double?

    public init(memory: Memory, similarity: Float? = nil, rrfScore: Double? = nil) {
        self.memory = memory
        self.similarity = similarity
        self.rrfScore = rrfScore
    }
}

// MARK: - Store

/// GRDB-backed memory store. Same concurrency stance as KnowledgeStore:
/// DatabaseQueue is internally serialized → @unchecked Sendable.
public final class MemoryStore: @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    /// `nil` path → in-memory store (tests).
    public init(path: String? = nil) throws {
        if let path {
            dbQueue = try DatabaseQueue(path: path)
        } else {
            dbQueue = try DatabaseQueue()
        }
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "memories") { t in
                t.column("id", .text).primaryKey()
                t.column("kind", .text).notNull().indexed()
                t.column("text", .text).notNull()
                t.column("source", .text).notNull()
                t.column("created_at", .double).notNull()
                t.column("superseded_by", .text) // nil = live
            }
            // FTS5 mirror — id carried UNINDEXED, same as knowledge_chunk_fts.
            try db.execute(sql: """
            CREATE VIRTUAL TABLE memory_fts USING fts5(id UNINDEXED, text)
            """)
            // One vector per memory (it's atomic — no chunk table needed).
            try db.create(table: "memory_embeddings") { t in
                t.column("memory_id", .text).primaryKey()
                t.column("embedding", .blob).notNull()
            }
            // The graph. Composite PK = one edge per (from, to, relation).
            try db.create(table: "memory_edges") { t in
                t.column("from_id", .text).notNull().indexed()
                t.column("to_id", .text).notNull().indexed()
                t.column("relation", .text).notNull()
                t.column("created_at", .double).notNull()
                t.primaryKey(["from_id", "to_id", "relation"])
            }
            // Embedder fingerprint + future markers (knowledge_meta pattern).
            try db.create(table: "memory_meta") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
        }
        // v2 (2026-07-09): optional title — B5 layer-3 composition for the
        // graph lane. Nullable, so every v1 row reads back unchanged.
        migrator.registerMigration("v2-title") { db in
            try db.alter(table: "memories") { t in
                t.add(column: "title", .text)
            }
        }
        try migrator.migrate(dbQueue)
    }

    // MARK: - Write

    /// Store a memory and its embedding atomically.
    /// `supersedes` marks an older memory as corrected by this one and records
    /// the edge — recall stops returning the old row, history keeps it.
    ///
    /// Supersession can CHAIN (A←B←C: C supersedes B which superseded A). Only
    /// the latest is live; each older row points at its immediate corrector.
    /// `forget` undoes exactly one link: deleting B revives A (B's predecessor)
    /// and leaves C live — it does not walk the chain. That's deliberate: undo
    /// is one step, not a cascade.
    public func remember(
        _ memory: Memory,
        embedding: [Float],
        supersedes oldID: UUID? = nil
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO memories (id, kind, text, title, source, created_at, superseded_by)
                VALUES (?, ?, ?, ?, ?, ?, NULL)
                """,
                arguments: [
                    memory.id.uuidString, memory.kind.rawValue, memory.text, memory.title,
                    memory.source, memory.createdAt.timeIntervalSince1970,
                ]
            )
            try db.execute(
                sql: "INSERT INTO memory_fts (id, text) VALUES (?, ?)",
                arguments: [memory.id.uuidString, memory.text]
            )
            try db.execute(
                sql: "INSERT INTO memory_embeddings (memory_id, embedding) VALUES (?, ?)",
                arguments: [memory.id.uuidString, VectorMath.serialize(embedding)]
            )
            if let oldID {
                try db.execute(
                    sql: "UPDATE memories SET superseded_by = ? WHERE id = ?",
                    arguments: [memory.id.uuidString, oldID.uuidString]
                )
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO memory_edges (from_id, to_id, relation, created_at)
                    VALUES (?, ?, 'supersedes', ?)
                    """,
                    arguments: [
                        memory.id.uuidString, oldID.uuidString,
                        memory.createdAt.timeIntervalSince1970,
                    ]
                )
            }
        }
    }

    /// Record a typed, directed edge between two memories. Idempotent on the
    /// (from, to, relation) composite key.
    public func link(_ edge: MemoryEdge) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT OR IGNORE INTO memory_edges (from_id, to_id, relation, created_at)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [
                    edge.fromID.uuidString, edge.toID.uuidString,
                    edge.relation, edge.createdAt.timeIntervalSince1970,
                ]
            )
        }
    }

    /// Remember a fact AND weave it into the graph: insert the node, then link
    /// it (relation "related") to the most semantically-similar existing LIVE
    /// facts above `threshold`, capped at `maxLinks`. This is what makes the
    /// store an actual graph as it grows — plain `remember` only ever creates a
    /// node (and a supersedes edge on correction), which left `related` and the
    /// constellation edgeless in production. The cosine bar keeps unrelated
    /// facts unlinked — DELIBERATELY stricter than recall's memoryThreshold
    /// since 2026-07-08: a weak recall hit is one extra line in a prompt, a
    /// weak edge is permanent graph structure feeding traversal, so edges
    /// keep their own bar (GroundingGate.edgeThreshold, 0.51 — since 07-09 a
    /// dedicated constant: fact↔fact cosines carry no query instruction, so
    /// this bar did not move with the query-side floor re-tune). Revisit if the
    /// constellation looks under-linked for identity facts. `maxLinks` caps
    /// degree so a common topic can't hairball. Returns the number of edges
    /// created.
    ///
    /// Node + edges are SEPARATE writes (not one transaction): a crash mid-loop
    /// leaves the node intact and recallable with some edges missing — acceptable
    /// for a best-effort personal graph, and `link`'s INSERT OR IGNORE keeps
    /// retries idempotent. ⚠️ But a THROW mid-loop is permanently masked one
    /// layer up: the fact's vector is already in the corpus, so the distiller's
    /// semantic dedup (`semanticTwin` / `wasDeduped`) handles it on every
    /// retry and the missing edges are never backfilled (112 review nit). That's
    /// why a mid-loop throw is wrapped in `MemoryGraphPartialWriteError` naming
    /// the partial X/N state — so the caller's breadcrumb says "node written,
    /// N−X edges lost", not a misleading "skipped". Facts distilled before this
    /// path existed live in the corpus only and are NOT backfilled here — the
    /// graph accretes from new writes (a one-shot backfill/scrub is a separate,
    /// manual step).
    @discardableResult
    public func rememberConnected(
        _ memory: Memory,
        embedding: [Float],
        maxLinks: Int = 3,
        threshold: Float = GroundingGate.edgeThreshold,
        supersedes oldID: UUID? = nil
    ) throws -> Int {
        try remember(memory, embedding: embedding, supersedes: oldID)
        // Nearest live neighbours by cosine — the +1 absorbs the node we just
        // inserted (cosine 1.0 with itself), which we then drop by id.
        let neighbours = try recallVector(queryVector: embedding, limit: maxLinks + 1)
            .filter { $0.memory.id != memory.id && ($0.similarity ?? 0) >= threshold }
            .prefix(maxLinks)
        for (index, n) in neighbours.enumerated() {
            do {
                try link(MemoryEdge(
                    fromID: memory.id, toID: n.memory.id,
                    relation: "related", createdAt: memory.createdAt
                ))
            } catch {
                throw MemoryGraphPartialWriteError(
                    memoryID: memory.id, edgesLinked: index,
                    edgesPlanned: neighbours.count, underlying: error
                )
            }
        }
        return neighbours.count
    }

    /// Hard-delete: the row, its vector, its FTS mirror, every edge touching
    /// it. THE consent primitive — "forget that" must leave no residue.
    /// Manual cascade because FTS5 ignores ON DELETE CASCADE (KnowledgeStore
    /// precedent).
    @discardableResult
    public func forget(id: UUID) throws -> Bool {
        try dbQueue.write { db in
            let mid = id.uuidString
            let exists = try Int.fetchOne(
                db, sql: "SELECT 1 FROM memories WHERE id = ?", arguments: [mid]
            ) != nil
            guard exists else { return false }
            try db.execute(sql: "DELETE FROM memory_fts WHERE id = ?", arguments: [mid])
            try db.execute(sql: "DELETE FROM memory_embeddings WHERE memory_id = ?", arguments: [mid])
            try db.execute(
                sql: "DELETE FROM memory_edges WHERE from_id = ? OR to_id = ?",
                arguments: [mid, mid]
            )
            // Anything this row superseded becomes live again (undo semantics).
            try db.execute(
                sql: "UPDATE memories SET superseded_by = NULL WHERE superseded_by = ?",
                arguments: [mid]
            )
            try db.execute(sql: "DELETE FROM memories WHERE id = ?", arguments: [mid])
            return true
        }
    }

    // MARK: - Recall (the retrieval-with-cutoff query)

    /// Hybrid recall: FTS5 BM25 + brute-force cosine, fused with RRF, then
    /// EVERY hit must clear the cosine bar individually — keyword-only hits
    /// never sneak past (the GroundingGate.filter lesson, applied at source).
    /// Superseded memories are excluded. Ties broken newest-first so a recent
    /// fact beats an old near-duplicate.
    public func recall(
        query: String,
        queryVector: [Float],
        limit: Int = 5,
        threshold: Float = GroundingGate.memoryThreshold
    ) throws -> [MemoryHit] {
        let ftsHits = try recallFTS(query: query, limit: limit * 2)
        let vectorHits = try recallVector(queryVector: queryVector, limit: limit * 2)

        let fused = ReciprocalRankFusion.fuseScored(
            rankings: [ftsHits, vectorHits],
            key: { $0.memory.id }
        )
        // Backfill similarity onto FTS-first instances (KnowledgeStore
        // searchHybrid pattern) so the cutoff sees both signals on every hit.
        let similarityByID = Dictionary(
            vectorHits.compactMap { hit in hit.similarity.map { (hit.memory.id, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        var scored = fused.map { item, score -> MemoryHit in
            var hit = item
            hit.rrfScore = score
            if hit.similarity == nil { hit.similarity = similarityByID[hit.memory.id] }
            return hit
        }
        // An FTS-lane hit OUTSIDE the vector top-K still has similarity == nil
        // here, and the cutoff drops nil UNJUDGED — which discarded a
        // keyword-exact memory whose embedding was one read away (the same
        // Golden Gate miss KnowledgeStore.searchHybrid was fixed for; this graph
        // lane never got the second half). Judge those on their STORED
        // embeddings before the cutoff: a bounded handful of blob reads, and
        // genuinely irrelevant keyword matches still fall to the threshold — the
        // no-keyword-flood rule survives, now enforced on real scores.
        let unscored = scored.filter { $0.similarity == nil }.map(\.memory.id)
        if !unscored.isEmpty, !queryVector.isEmpty {
            let stored = try storedEmbeddings(forMemoryIDs: unscored)
            for index in scored.indices where scored[index].similarity == nil {
                guard let blob = stored[scored[index].memory.id] else { continue }
                scored[index].similarity = VectorMath.cosineSimilarity(
                    queryVector, VectorMath.deserialize(blob)
                )
            }
        }
        return scored
            .filter { ($0.similarity ?? 0) >= threshold } // the cutoff — no exceptions
            .sorted {
                if $0.rrfScore != $1.rrfScore { return ($0.rrfScore ?? 0) > ($1.rrfScore ?? 0) }
                return $0.memory.createdAt > $1.memory.createdAt
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Strict-then-relaxed FTS lane (same rule as KnowledgeStore.searchFTS):
    /// FTS5's implicit AND starves natural multi-term queries, so a zero-hit
    /// strict pass retries OR-joined — BM25 ranks best coverage, and the
    /// cosine floor in `recall` still gates every hit. Internal (not private)
    /// so the relaxation is test-pinned.
    func recallFTS(query: String, limit: Int) throws -> [MemoryHit] {
        guard let strict = FTSQuery.sanitized(query) else { return [] }
        let hits = try ftsMatch(strict, limit: limit)
        if !hits.isEmpty { return hits }
        guard let relaxed = FTSQuery.relaxed(query) else { return [] }
        return try ftsMatch(relaxed, limit: limit)
    }

    /// One FTS5 MATCH execution — shared by the strict pass and the relaxed retry.
    private func ftsMatch(_ match: String, limit: Int) throws -> [MemoryHit] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT m.* FROM memory_fts fts
                JOIN memories m ON m.id = fts.id
                WHERE memory_fts MATCH ? AND m.superseded_by IS NULL
                ORDER BY bm25(memory_fts) ASC
                LIMIT ?
                """,
                arguments: [match, limit]
            )
            return rows.compactMap { Self.memory(from: $0).map { MemoryHit(memory: $0) } }
        }
    }

    private func recallVector(queryVector: [Float], limit: Int) throws -> [MemoryHit] {
        let rows = try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT m.*, e.embedding FROM memory_embeddings e
                JOIN memories m ON m.id = e.memory_id
                WHERE m.superseded_by IS NULL
                """
            )
        }
        var scored: [MemoryHit] = []
        scored.reserveCapacity(rows.count)
        for row in rows {
            guard let blob: Data = row["embedding"],
                  let memory = Self.memory(from: row) else { continue }
            scored.append(MemoryHit(
                memory: memory,
                similarity: VectorMath.cosineSimilarity(queryVector, VectorMath.deserialize(blob))
            ))
        }
        scored.sort { ($0.similarity ?? 0) > ($1.similarity ?? 0) }
        return Array(scored.prefix(limit))
    }

    /// Embedding blobs for specific memories — the hybrid backfill's single read
    /// (mirrors KnowledgeStore.storedEmbeddings(forChunkIDs:)). Lets recall score
    /// an FTS-only hit that ranks outside the vector top-K without re-embedding.
    private func storedEmbeddings(forMemoryIDs ids: [UUID]) throws -> [UUID: Data] {
        try dbQueue.read { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT memory_id, embedding FROM memory_embeddings WHERE memory_id IN (\(placeholders))",
                arguments: StatementArguments(ids.map(\.uuidString))
            )
            var blobs: [UUID: Data] = [:]
            for row in rows {
                guard let raw: String = row["memory_id"], let id = UUID(uuidString: raw),
                      let blob: Data = row["embedding"] else { continue }
                blobs[id] = blob
            }
            return blobs
        }
    }

    // MARK: - Graph traversal (the recursive CTE)

    /// Everything connected to a memory within `maxHops`, undirected, nearest
    /// hops first. This IS the graph layer — one query, no graph engine.
    ///
    /// `UNION` (not `UNION ALL`) is deliberate: it dedupes whole `(id, hops)`
    /// rows so the recursion can't loop forever on a cycle. SQLite has no native
    /// cycle guard, so a cycle still re-visits a node at increasing hop counts
    /// until `r.hops < maxHops` bottoms out — bounded, never infinite. The outer
    /// `GROUP BY m.id` + `MIN(hops)` then collapses those revisits to one row
    /// per node at its nearest distance, so the RESULT is correct; the only cost
    /// is some redundant intermediate rows on dense cyclic graphs (negligible at
    /// the default maxHops 2 over a personal store). Pinned by relatedWithCycle.
    public func related(to id: UUID, maxHops: Int = 2, limit: Int = 20) throws -> [Memory] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                WITH RECURSIVE reachable(id, hops) AS (
                    SELECT ?, 0
                    UNION
                    SELECT CASE WHEN e.from_id = r.id THEN e.to_id ELSE e.from_id END,
                           r.hops + 1
                    FROM memory_edges e
                    JOIN reachable r ON r.id IN (e.from_id, e.to_id)
                    WHERE r.hops < ?
                )
                SELECT m.*, MIN(r.hops) AS hops FROM reachable r
                JOIN memories m ON m.id = r.id
                WHERE r.id != ? AND m.superseded_by IS NULL
                GROUP BY m.id
                ORDER BY hops ASC, m.created_at DESC
                LIMIT ?
                """,
                arguments: [id.uuidString, maxHops, id.uuidString, limit]
            )
            return rows.compactMap { Self.memory(from: $0) }
        }
    }

    // MARK: - Maintenance

    public static let embedderFingerprintKey = "embedder.fingerprint"

    /// Set BEFORE any title backfill writes and cleared only after the
    /// vector-repairing reindex completes — a crash between the two phases
    /// leaves this flag, and the next pass forces the reindex it still owes
    /// (otherwise: titled rows + matching fingerprint = stranded bare vectors).
    public static let titleBackfillPendingKey = "title.backfill.pending"

    /// Re-embed everything when the embedder changes — same atomic
    /// vectors+fingerprint contract as KnowledgeStore.reindexEmbeddings.
    ///
    /// Re-embeds SUPERSEDED rows too, not just live ones: `forget`-the-corrector
    /// can revive a superseded memory (undo), so its vector must stay valid
    /// across an embedder change. Skipping them would save a little work at the
    /// cost of a revived memory carrying a stale-dimension vector that silently
    /// fails the cosine bar. Correctness over the saving.
    ///
    /// TOCTOU: the read → async embed → write spans three steps. A `forget` that
    /// interleaves between the read and the write leaves an orphan embedding (no
    /// matching `memories` row) — invisible to recall via the JOIN, harmless but
    /// for a little space. The serialized DatabaseQueue makes each step atomic,
    /// not the whole sequence.
    @discardableResult
    public func reindexEmbeddings(
        using embedder: any EmbeddingService,
        fingerprint: String? = nil
    ) async throws -> Int {
        // Re-embed the COMPOSED text (title-prefixed via the forChunk rules),
        // never the bare row text — same doctrine as KnowledgeStore's reindex.
        let rows: [(id: String, composed: String)] = try await dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT id, text, title FROM memories").compactMap { row in
                guard let id: String = row["id"] else { return nil }
                return (id, EmbeddingText.forChunk(title: row["title"] ?? "", content: row["text"] ?? ""))
            }
        }
        guard !rows.isEmpty else {
            // An empty store still adopts the marker — "zero vectors in this
            // space" is a true statement, and a markerless fresh graph would
            // otherwise re-enter the reindex decision every launch.
            if let fingerprint {
                try await dbQueue.write { db in
                    try db.execute(
                        sql: """
                        INSERT INTO memory_meta (key, value) VALUES (?, ?)
                        ON CONFLICT(key) DO UPDATE SET value = excluded.value
                        """,
                        arguments: [Self.embedderFingerprintKey, fingerprint]
                    )
                }
            }
            return 0
        }
        let vectors = try await embedder.embedBatch(rows.map(\.composed))
        try await dbQueue.write { db in
            for (row, vector) in zip(rows, vectors) {
                try db.execute(
                    sql: """
                    INSERT INTO memory_embeddings (memory_id, embedding) VALUES (?, ?)
                    ON CONFLICT(memory_id) DO UPDATE SET embedding = excluded.embedding
                    """,
                    arguments: [row.id, VectorMath.serialize(vector)]
                )
            }
            if let fingerprint {
                try db.execute(
                    sql: """
                    INSERT INTO memory_meta (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                    arguments: [Self.embedderFingerprintKey, fingerprint]
                )
            }
        }
        return rows.count
    }

    /// Stored meta value (the app wiring reads the embedder fingerprint to
    /// drive the reindex decision — the corpus store's `meta(key:)` twin).
    public func meta(key: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM memory_meta WHERE key = ?", arguments: [key])
        }
    }

    /// Write a meta value (the corpus store's `setMeta` twin).
    public func setMeta(key: String, value: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO memory_meta (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [key, value]
            )
        }
    }

    /// Remove a meta value (clears one-shot flags like the backfill pending
    /// marker).
    public func deleteMeta(key: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM memory_meta WHERE key = ?", arguments: [key])
        }
    }

    /// How many vectors exist — the reindex policy's "is there anything to
    /// migrate" input.
    public func embeddingCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memory_embeddings") ?? 0
        }
    }

    /// Memories with no title yet — the one-time backfill's work list (the
    /// app copies titles across from the corpus twins written by the same
    /// `remember`, so pre-v2 facts get their discriminating context back).
    public func memoriesWithoutTitle() throws -> [Memory] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM memories WHERE title IS NULL ORDER BY created_at")
                .compactMap(Self.memory(from:))
        }
    }

    /// Backfill a title. Touches the ROW only — the vector is repaired by the
    /// reindex that follows the backfill (composition changes the embedding
    /// text, and only the reindex owns vector writes).
    public func setTitle(_ title: String, for id: UUID) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE memories SET title = ? WHERE id = ?",
                arguments: [title, id.uuidString]
            )
        }
    }

    /// Live (non-superseded) memory count — the Settings "M1K3 remembers
    /// N things about you" number.
    public func liveCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM memories WHERE superseded_by IS NULL"
            ) ?? 0
        }
    }

    /// The newest LIVE row whose text matches exactly — the write-time
    /// repair's join key (dream-cycle Tier 2): the dual-write puts the SAME
    /// fact text in both stores, so exact text is the honest corpus↔graph
    /// linkage (the same identity `factSourceRef` hashes on the corpus side).
    public func liveMemory(matchingText text: String) throws -> Memory? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM memories
                WHERE text = ? AND superseded_by IS NULL
                ORDER BY created_at DESC LIMIT 1
                """,
                arguments: [text]
            ).flatMap(Self.memory(from:))
        }
    }

    /// From a SUPERSEDED row carrying `text`, follow the supersede chain to
    /// its live head — the un-supersede-on-reassert join (Tier 2, spec
    /// finding #8). Nil when no superseded row carries the text. Bounded
    /// walk: chains are linear by construction; 64 hops is far beyond any
    /// real lifetime of corrections.
    public func liveSuccessor(ofText text: String) throws -> Memory? {
        let start: Memory? = try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM memories
                WHERE text = ? AND superseded_by IS NOT NULL
                ORDER BY created_at DESC LIMIT 1
                """,
                arguments: [text]
            ).flatMap(Self.memory(from:))
        }
        guard var current = start else { return nil }
        for _ in 0 ..< 64 {
            guard let nextID = current.supersededBy else { return current }
            // A dangling pointer means an inconsistent chain — degrade to nil
            // (caller plain-writes) rather than report a superseded node live.
            guard let next = try memory(id: nextID) else { return nil }
            current = next
        }
        return nil // cap hit — same degrade, never a non-live answer
    }

    /// Every row, superseded included — one aggregate read, no hydration
    /// (the MEMSTAT census's superseded-count input; PR #83 review fold).
    public func totalCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memories") ?? 0
        }
    }

    /// A cheap change-signal for polling UIs. `liveCount` alone MISSES a
    /// supersession (an old fact exits live as its corrector enters → net delta
    /// zero), so we fold in the edge count (a supersedes/link always writes an
    /// edge) and the newest live timestamp. One aggregate read, no row scan —
    /// the constellation gates its relayout on this so a correction redraws.
    public func revision() throws -> MemoryRevision {
        try dbQueue.read { db in
            let memoryCount = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM memories WHERE superseded_by IS NULL"
            ) ?? 0
            let edgeCount = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM memory_edges"
            ) ?? 0
            let latest = try Double.fetchOne(
                db, sql: "SELECT COALESCE(MAX(created_at), 0) FROM memories WHERE superseded_by IS NULL"
            ) ?? 0
            return MemoryRevision(memoryCount: memoryCount, edgeCount: edgeCount, latestCreatedAt: latest)
        }
    }

    /// Every live memory's vector — the MEMSTAT pairwise-census read
    /// (scratch/dream-cycle/SPEC.md Tier 0). Superseded rows are excluded:
    /// retrieval can never pair with them, so counting them would inflate
    /// the very bands the census exists to measure.
    public func liveEmbeddingVectors(limit: Int = 20000) throws -> [[Float]] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT e.embedding FROM memory_embeddings e
                JOIN memories m ON m.id = e.memory_id
                WHERE m.superseded_by IS NULL
                LIMIT ?
                """,
                arguments: [limit]
            )
            return rows.compactMap { row in
                (row["embedding"] as Data?).map(VectorMath.deserialize)
            }
        }
    }

    /// Live per-kind row counts (rawValue → count) — the MEMSTAT census header.
    public func liveCountsByKind() throws -> [String: Int] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT kind, COUNT(*) AS n FROM memories
                WHERE superseded_by IS NULL GROUP BY kind
                """
            )
            var counts: [String: Int] = [:]
            for row in rows {
                if let kind: String = row["kind"], let count: Int = row["n"] {
                    counts[kind] = count
                }
            }
            return counts
        }
    }

    /// Everything, newest first, for the Settings review/delete surface.
    /// Visibility is the other half of consent.
    public func allMemories(includeSuperseded: Bool = false, limit: Int = 500) throws -> [Memory] {
        // Two whole literals, not interpolation — there's no user input here, but
        // building SQL by string concat is a pattern not worth seeding.
        let sql = includeSuperseded
            ? "SELECT * FROM memories ORDER BY created_at DESC LIMIT ?"
            : "SELECT * FROM memories WHERE superseded_by IS NULL ORDER BY created_at DESC LIMIT ?"
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: [limit])
            return rows.compactMap { Self.memory(from: $0) }
        }
    }

    /// Corrected rows only (superseded_by set), newest first — the corrected-
    /// facts lens. Its OWN query and limit on purpose: sharing allMemories'
    /// row budget lets recent corrected rows displace live ones out of the
    /// fetched window, silently shrinking the live list/count (PR #94).
    public func supersededMemories(limit: Int = 500) throws -> [Memory] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM memories WHERE superseded_by IS NOT NULL ORDER BY created_at DESC LIMIT ?",
                arguments: [limit]
            )
            return rows.compactMap { Self.memory(from: $0) }
        }
    }

    /// Fetch a single memory by id, live or superseded. The app layer needs this
    /// to surface a just-written fact (e.g. echo back an MCP `remember`) without
    /// scanning the whole store.
    public func memory(id: UUID) throws -> Memory? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db, sql: "SELECT * FROM memories WHERE id = ?", arguments: [id.uuidString]
            )
            return row.flatMap { Self.memory(from: $0) }
        }
    }

    /// Every edge in the graph, oldest-first — the bulk read the constellation
    /// view needs to draw threads (recall/`related` only walk from a seed).
    public func allEdges(limit: Int = 5000) throws -> [MemoryEdge] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT from_id, to_id, relation, created_at FROM memory_edges
                ORDER BY created_at ASC LIMIT ?
                """,
                arguments: [limit]
            )
            return rows.compactMap { row -> MemoryEdge? in
                guard let from: String = row["from_id"], let fromID = UUID(uuidString: from),
                      let to: String = row["to_id"], let toID = UUID(uuidString: to)
                else { return nil }
                return MemoryEdge(
                    fromID: fromID, toID: toID,
                    relation: row["relation"] ?? "",
                    createdAt: Date(timeIntervalSince1970: row["created_at"] ?? 0)
                )
            }
        }
    }

    // MARK: - Row mapping

    private static func memory(from row: Row) -> Memory? {
        guard let raw: String = row["id"], let id = UUID(uuidString: raw) else { return nil }
        return Memory(
            id: id,
            kind: MemoryKind(rawValue: row["kind"] ?? "note"),
            text: row["text"] ?? "",
            title: row["title"],
            source: row["source"] ?? "unknown",
            createdAt: Date(timeIntervalSince1970: row["created_at"] ?? 0),
            supersededBy: (row["superseded_by"] as String?).flatMap(UUID.init(uuidString:))
        )
    }
}
