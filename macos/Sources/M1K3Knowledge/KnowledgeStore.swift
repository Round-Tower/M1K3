//
//  KnowledgeStore.swift
//  M1K3Knowledge
//
//  GRDB-backed semantic store: knowledge items + chunks + FTS5 + vector
//  embeddings + RRF hybrid search. The reusable mechanism is lifted from
//  the prior knowledge-server's SemanticStore (FTS5 BM25 + brute-force cosine KNN + Reciprocal
//  Rank Fusion); the schema is generalised to M1K3's domain-neutral model.
//
//  Embeddings are computed by the caller via an EmbeddingService and passed in
//  aligned with chunks — the store knows persistence and search, not how to
//  embed, so it carries no MLX dependency.
//
//  Concurrency: GRDB's DatabaseQueue is internally serialized; the class is
//  @unchecked Sendable for the same reason the prior knowledge-server's SemanticStore is.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.8,
//  Prior: internal knowledge-server project, SemanticStore + SemanticStore+Documents (Kev)
//  Review: Kev + claude-opus-4-8, 2026-06-13, Confidence 0.9 — optional `kinds`
//  filter on searchFTS/searchVector/searchHybrid + two-lane `searchGrounding`
//  (separate doc/memory budgets) so the document corpus can't crowd short
//  memory facts out of a single top-K (the open-chat recall miss). Pinned by
//  KnowledgeStoreGroundingTests; existing callers unaffected (filter defaults nil).

import Foundation
import GRDB

public final class KnowledgeStore: @unchecked Sendable {
    private let dbQueue: DatabaseQueue

    // MARK: - Init

    /// Open (or create) a store at `path`. Pass `nil` for an in-memory store
    /// (used by tests — no disk, fresh per instance).
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
            try db.create(table: "knowledge_items") { t in
                t.column("id", .text).primaryKey()
                t.column("kind", .text).notNull()
                t.column("title", .text).notNull()
                t.column("source_ref", .text)
                t.column("created_at", .double).notNull()
            }
            try db.create(table: "knowledge_chunks") { t in
                t.column("id", .text).primaryKey()
                t.column("item_id", .text).notNull().indexed()
                t.column("ordinal", .integer).notNull()
                t.column("heading", .text)
                t.column("content", .text).notNull()
            }
            // FTS5 mirror for BM25 full-text search. id/item_id carried
            // UNINDEXED so they round-trip without participating in matching.
            try db.execute(sql: """
            CREATE VIRTUAL TABLE knowledge_chunk_fts USING fts5(
                id UNINDEXED, item_id UNINDEXED, heading, content
            )
            """)
            try db.create(table: "knowledge_chunk_embeddings") { t in
                t.column("chunk_id", .text).primaryKey()
                t.column("item_id", .text).notNull().indexed()
                t.column("embedding", .blob).notNull()
            }
        }
        // Store-level metadata (e.g. which embedder fingerprint produced the
        // stored vectors). Tiny key-value table so future markers don't need
        // their own migrations.
        migrator.registerMigration("v2-meta") { db in
            try db.create(table: "knowledge_meta") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }
        }
        // Provenance for memory items: who wrote it ("user" | "distilled").
        // Nullable, no backfill — documents/calls legitimately have no source.
        migrator.registerMigration("v3-source") { db in
            try db.alter(table: "knowledge_items") { t in
                t.add(column: "source", .text)
            }
        }
        try migrator.migrate(dbQueue)
    }

    // MARK: - Meta

    /// The meta key recording which embedder fingerprint produced the stored
    /// vectors (see `EmbedderReindexPolicy`).
    public static let embedderFingerprintKey = "embedder.fingerprint"

    public func meta(key: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(
                db, sql: "SELECT value FROM knowledge_meta WHERE key = ?", arguments: [key]
            )
        }
    }

    public func setMeta(key: String, value: String) throws {
        try dbQueue.write { db in
            try Self.upsertMeta(db, key: key, value: value)
        }
    }

    public func deleteMeta(key: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM knowledge_meta WHERE key = ?", arguments: [key])
        }
    }

    private static func upsertMeta(_ db: Database, key: String, value: String) throws {
        try db.execute(
            sql: """
            INSERT INTO knowledge_meta (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            arguments: [key, value]
        )
    }

    // MARK: - Indexing

    /// Index an item and its chunks atomically. `embeddings`, when provided,
    /// must align 1:1 with `chunks`; pass `nil` to index text-only (FTS-only,
    /// embeddings can be backfilled later via `setEmbedding`).
    public func index(
        item: KnowledgeItem,
        chunks: [KnowledgeChunk],
        embeddings: [[Float]]? = nil
    ) throws {
        if let embeddings, embeddings.count != chunks.count {
            throw KnowledgeStoreError.embeddingCountMismatch(
                chunks: chunks.count, embeddings: embeddings.count
            )
        }
        try dbQueue.write { db in
            try ItemRecord(item).insert(db)
            for (offset, chunk) in chunks.enumerated() {
                try ChunkRecord(chunk).insert(db)
                try db.execute(
                    sql: """
                    INSERT INTO knowledge_chunk_fts (id, item_id, heading, content)
                    VALUES (?, ?, ?, ?)
                    """,
                    arguments: [chunk.id.uuidString, chunk.itemID.uuidString, chunk.heading, chunk.content]
                )
                if let embeddings {
                    try db.execute(
                        sql: """
                        INSERT INTO knowledge_chunk_embeddings (chunk_id, item_id, embedding)
                        VALUES (?, ?, ?)
                        """,
                        arguments: [
                            chunk.id.uuidString,
                            chunk.itemID.uuidString,
                            VectorMath.serialize(embeddings[offset]),
                        ]
                    )
                }
            }
        }
    }

    /// Backfill or replace a single chunk's embedding.
    public func setEmbedding(chunkID: UUID, itemID: UUID, vector: [Float]) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO knowledge_chunk_embeddings (chunk_id, item_id, embedding)
                VALUES (?, ?, ?)
                ON CONFLICT(chunk_id) DO UPDATE SET embedding = excluded.embedding
                """,
                arguments: [chunkID.uuidString, itemID.uuidString, VectorMath.serialize(vector)]
            )
        }
    }

    /// Re-embed every stored chunk with `embedder`, replacing existing vectors
    /// in one pass. Use when switching embedders (e.g. Hashing fallback → MLX):
    /// the stored vectors define the search space, so a half-migrated store would
    /// compare incompatible vectors. Returns the number of chunks re-embedded.
    ///
    /// Pass `fingerprint` to record the new vectors' provenance in the same
    /// write transaction (atomically: the marker can never claim vectors that
    /// weren't written).
    @discardableResult
    public func reindexEmbeddings(
        using embedder: any EmbeddingService,
        fingerprint: String? = nil
    ) async throws -> Int {
        // Snapshot (chunkID, itemID, embed-text) for every chunk first, so the
        // async embed happens outside any DB transaction. The embed text is the
        // SAME title-prefixed composition ingest uses (EmbeddingText) — a
        // reindex that composed differently would silently fork the space.
        let rows: [(chunkID: UUID, itemID: UUID, text: String)] = try await dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT c.id, c.item_id, c.content, i.title
                FROM knowledge_chunks c
                JOIN knowledge_items i ON i.id = c.item_id
                """
            )
            .compactMap { row -> (chunkID: UUID, itemID: UUID, text: String)? in
                guard let cid: String = row["id"], let chunkID = UUID(uuidString: cid),
                      let iid: String = row["item_id"], let itemID = UUID(uuidString: iid)
                else { return nil }
                let content: String = row["content"] ?? ""
                let title: String = row["title"] ?? ""
                return (chunkID, itemID, EmbeddingText.forChunk(title: title, content: content))
            }
        }
        guard !rows.isEmpty else { return 0 }

        let vectors = try await embedder.embedBatch(rows.map(\.text))
        guard vectors.count == rows.count else {
            throw KnowledgeStoreError.embeddingCountMismatch(chunks: rows.count, embeddings: vectors.count)
        }

        try await dbQueue.write { db in
            for (row, vector) in zip(rows, vectors) {
                try db.execute(
                    sql: """
                    INSERT INTO knowledge_chunk_embeddings (chunk_id, item_id, embedding)
                    VALUES (?, ?, ?)
                    ON CONFLICT(chunk_id) DO UPDATE SET embedding = excluded.embedding
                    """,
                    arguments: [row.chunkID.uuidString, row.itemID.uuidString, VectorMath.serialize(vector)]
                )
            }
            if let fingerprint {
                try Self.upsertMeta(db, key: Self.embedderFingerprintKey, value: fingerprint)
            }
        }
        return rows.count
    }

    /// The existing item id if one with this `sourceRef` is already indexed.
    public func itemID(forSourceRef sourceRef: String) throws -> UUID? {
        try dbQueue.read { db in
            let raw = try String.fetchOne(
                db,
                sql: "SELECT id FROM knowledge_items WHERE source_ref = ?",
                arguments: [sourceRef]
            )
            return raw.flatMap(UUID.init(uuidString:))
        }
    }

    public func itemCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM knowledge_items") ?? 0
        }
    }

    public func chunkCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM knowledge_chunks") ?? 0
        }
    }

    /// Number of chunks that currently carry an embedding vector. Lets callers
    /// see how much of the store is vector-searchable (vs FTS-only).
    public func embeddingCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM knowledge_chunk_embeddings") ?? 0
        }
    }

    /// Update a persisted item's kind in-place. Returns true if the item was
    /// found and updated; false if no row matched the id.
    ///
    /// Embeddings and FTS are unchanged — index segregation is kind-based, not
    /// physical removal, so vectors stay valid if the kind is changed back later.
    @discardableResult
    public func setKind(id: UUID, newKind: KnowledgeKind) throws -> Bool {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE knowledge_items SET kind = ? WHERE id = ?",
                arguments: [newKind.rawValue, id.uuidString]
            )
            return db.changesCount > 0
        }
    }

    /// Hard-delete an item and every row it owns (chunks, FTS mirror,
    /// embeddings). Manual cascade — FTS5 doesn't honour ON DELETE CASCADE.
    @discardableResult
    public func deleteItem(id: UUID) throws -> Bool {
        try dbQueue.write { db in
            let iid = id.uuidString
            let exists = try Int.fetchOne(
                db, sql: "SELECT 1 FROM knowledge_items WHERE id = ?", arguments: [iid]
            ) != nil
            guard exists else { return false }
            try db.execute(sql: "DELETE FROM knowledge_chunk_fts WHERE item_id = ?", arguments: [iid])
            try db.execute(sql: "DELETE FROM knowledge_chunk_embeddings WHERE item_id = ?", arguments: [iid])
            try db.execute(sql: "DELETE FROM knowledge_chunks WHERE item_id = ?", arguments: [iid])
            try db.execute(sql: "DELETE FROM knowledge_items WHERE id = ?", arguments: [iid])
            return true
        }
    }

    // MARK: - Fetch (for document tools + MCP resources)

    /// Fetch a single item by id, or nil if absent.
    ///
    /// ⚠️ NO kind filter: a `.quarantined` item IS returned. Any caller that
    /// renders content to a model or an agent surface must apply its own
    /// quarantine check (the MCP get_document leak, fixed 2026-07-12, is the
    /// cautionary tale). The search/list surfaces are already gated.
    public func item(id: UUID) throws -> KnowledgeItem? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM knowledge_items WHERE id = ?", arguments: [id.uuidString]
            ) else { return nil }
            return Self.item(from: row)
        }
    }

    /// List items, newest first. Optionally filter by kind. The default (nil)
    /// listing covers every RETRIEVABLE kind — quarantined items appear only
    /// when asked for by name, same rule as the search surfaces, so the
    /// agent-facing list/get tools never enumerate them.
    public func allItems(kind: KnowledgeKind? = nil, limit: Int = 200) throws -> [KnowledgeItem] {
        try dbQueue.read { db in
            let rows: [Row]
            if let kind {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM knowledge_items WHERE kind = ? ORDER BY created_at DESC LIMIT ?",
                    arguments: [kind.rawValue, limit]
                )
            } else {
                let hidden = KnowledgeKind.hiddenFromRetrieval.map(\.rawValue).sorted()
                let holes = hidden.map { _ in "?" }.joined(separator: ", ")
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM knowledge_items WHERE kind NOT IN (\(holes)) "
                        + "ORDER BY created_at DESC LIMIT ?",
                    arguments: StatementArguments(hidden.map { $0 as DatabaseValueConvertible } + [limit])
                )
            }
            return rows.compactMap { Self.item(from: $0) }
        }
    }

    /// Fetch an item's chunks in order.
    ///
    /// ⚠️ NO kind filter — same caveat as `item(id:)`: check the owning
    /// item's kind before rendering these to a model-facing surface.
    public func chunks(forItem itemID: UUID) throws -> [KnowledgeChunk] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM knowledge_chunks WHERE item_id = ? ORDER BY ordinal",
                arguments: [itemID.uuidString]
            )
            return rows.compactMap { row -> KnowledgeChunk? in
                guard let cid: String = row["id"], let chunkID = UUID(uuidString: cid),
                      let iid: String = row["item_id"], let parsedItemID = UUID(uuidString: iid)
                else { return nil }
                return KnowledgeChunk(
                    id: chunkID,
                    itemID: parsedItemID,
                    ordinal: row["ordinal"] ?? 0,
                    heading: row["heading"],
                    content: row["content"] ?? ""
                )
            }
        }
    }

    private static func item(from row: Row) -> KnowledgeItem? {
        guard let raw: String = row["id"], let id = UUID(uuidString: raw) else { return nil }
        return KnowledgeItem(
            id: id,
            kind: KnowledgeKind(rawValue: row["kind"] ?? "note"),
            title: row["title"] ?? "",
            sourceRef: row["source_ref"],
            source: (row["source"] as String?).map(KnowledgeSource.init(rawValue:)),
            createdAt: Date(timeIntervalSince1970: row["created_at"] ?? 0)
        )
    }
}

// MARK: - Retrieval

/// FTS, vector, hybrid-fusion, and two-lane grounding search. Kept in a
/// same-file extension so the class body stays under the type_body_length
/// ceiling — `dbQueue` and the other `private` members stay reachable because a
/// same-file extension shares the type's private access (no visibility widening).
public extension KnowledgeStore {
    /// FTS5 BM25 search over chunk text. Each query word is double-quoted to
    /// neutralise FTS5 operators (same sanitisation as the prior knowledge-server).
    ///
    /// Precision first, recall fallback: FTS5's implicit AND demands every token
    /// in one chunk, so a natural multi-term question can starve retrieval to
    /// zero even when a chunk covers most of it (live 2026-07-02: a stored
    /// memory was listed but unfindable). When the strict query returns nothing,
    /// retry OR-joined — BM25 still ranks the best-covered chunk first, and the
    /// hybrid/grounding layers gate relevance downstream.
    func searchFTS(
        query: String, limit: Int = 10, kinds: Set<KnowledgeKind>? = nil
    ) throws -> [ChunkHit] {
        guard let sanitized = FTSQuery.sanitized(query) else { return [] }
        let strict = try ftsMatch(sanitized, limit: limit, kinds: kinds)
        if !strict.isEmpty { return strict }
        guard let relaxed = FTSQuery.relaxed(query) else { return [] }
        return try ftsMatch(relaxed, limit: limit, kinds: kinds)
    }

    /// One FTS5 MATCH execution — shared by the strict pass and the relaxed retry.
    private func ftsMatch(
        _ match: String, limit: Int, kinds: Set<KnowledgeKind>?
    ) throws -> [ChunkHit] {
        try dbQueue.read { db in
            var sql = """
            SELECT c.id AS chunk_id, c.item_id, c.heading, c.content,
                   i.title, i.kind, i.created_at AS item_created_at
            FROM knowledge_chunk_fts fts
            JOIN knowledge_chunks c ON c.id = fts.id
            JOIN knowledge_items i ON i.id = c.item_id
            WHERE knowledge_chunk_fts MATCH ?
            """
            var args: [DatabaseValueConvertible] = [match]
            if let kinds, !kinds.isEmpty {
                let placeholders = kinds.map { _ in "?" }.joined(separator: ", ")
                sql += "\nAND i.kind IN (\(placeholders))"
                args += kinds.map(\.rawValue)
            } else {
                // nil kinds = every RETRIEVABLE kind. Hidden kinds (quarantined,
                // superseded memory twins) are reachable only by naming the
                // kind (index segregation).
                let hidden = KnowledgeKind.hiddenFromRetrieval.map(\.rawValue).sorted()
                sql += "\nAND i.kind NOT IN (" + hidden.map { _ in "?" }.joined(separator: ", ") + ")"
                args += hidden
            }
            sql += "\nORDER BY bm25(knowledge_chunk_fts) ASC\nLIMIT ?"
            args.append(limit)
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.compactMap { Self.hit(from: $0) }
        }
    }

    /// Brute-force cosine KNN over stored embeddings. Single read, in-memory
    /// score + sort + prefix — fine for MVP volumes; revisit past ~10k chunks.
    func searchVector(
        queryVector: [Float], limit: Int = 10, kinds: Set<KnowledgeKind>? = nil
    ) throws -> [ChunkHit] {
        let rows = try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT e.chunk_id, e.embedding, c.item_id, c.heading, c.content,
                       i.title, i.kind, i.created_at AS item_created_at
                FROM knowledge_chunk_embeddings e
                JOIN knowledge_chunks c ON c.id = e.chunk_id
                JOIN knowledge_items i ON i.id = c.item_id
                """
            )
        }
        guard !rows.isEmpty else { return [] }

        var scored: [ChunkHit] = []
        scored.reserveCapacity(rows.count)
        for row in rows {
            guard let blob: Data = row["embedding"],
                  var hit = Self.hit(from: row, chunkIDColumn: "chunk_id")
            else { continue }
            if let kinds, !kinds.isEmpty {
                if !kinds.contains(hit.kind) { continue }
            } else if KnowledgeKind.hiddenFromRetrieval.contains(hit.kind) {
                // nil kinds = every RETRIEVABLE kind (index segregation).
                continue
            }
            hit.similarity = VectorMath.cosineSimilarity(queryVector, VectorMath.deserialize(blob))
            scored.append(hit)
        }
        scored.sort { ($0.similarity ?? 0) > ($1.similarity ?? 0) }
        return Array(scored.prefix(limit))
    }

    /// Hybrid search: fuse FTS and vector rankings with Reciprocal Rank Fusion.
    /// An item strong in both signals ranks above one strong in either alone.
    func searchHybrid(
        query: String,
        queryVector: [Float],
        limit: Int = 10,
        kinds: Set<KnowledgeKind>? = nil
    ) throws -> [ChunkHit] {
        // Pull a wider candidate set from each signal before fusing.
        let ftsHits = try searchFTS(query: query, limit: limit * 2, kinds: kinds)
        let vectorHits = try searchVector(queryVector: queryVector, limit: limit * 2, kinds: kinds)
        let fused = ReciprocalRankFusion.fuseScored(
            rankings: [ftsHits, vectorHits],
            key: { $0.chunkID }
        )
        // Fusion keeps the FIRST-seen instance (FTS), which has no similarity —
        // backfill it from the vector ranking, and stamp the fused score, so
        // downstream relevance gating has both signals on every hit.
        let similarityByChunk = Dictionary(
            vectorHits.compactMap { hit in hit.similarity.map { (hit.chunkID, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        var results = fused.prefix(limit).map { item, score in
            var hit = item
            hit.rrfScore = score
            if hit.similarity == nil {
                hit.similarity = similarityByChunk[hit.chunkID]
            }
            return hit
        }
        // An FTS-lane hit OUTSIDE the vector top-K still has similarity == nil
        // here, and the grounding gate drops nil unjudged — which discarded a
        // keyword-exact memory whose embedding was one read away (live
        // 2026-07-02, the Golden Gate miss). Judge such hits on their STORED
        // embeddings: at most `limit` extra blob reads, and genuinely
        // irrelevant keyword matches still fall to the gate's threshold —
        // the no-keyword-flood rule survives, now enforced on real scores.
        let unscored = results.filter { $0.similarity == nil }.map(\.chunkID)
        if !unscored.isEmpty, !queryVector.isEmpty {
            let stored = try storedEmbeddings(forChunkIDs: unscored)
            for index in results.indices where results[index].similarity == nil {
                guard let blob = stored[results[index].chunkID] else { continue }
                results[index].similarity = VectorMath.cosineSimilarity(
                    queryVector, VectorMath.deserialize(blob)
                )
            }
        }
        return results
    }

    /// Embedding blobs for specific chunks — the hybrid backfill's single read.
    private func storedEmbeddings(forChunkIDs ids: [UUID]) throws -> [UUID: Data] {
        try dbQueue.read { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT chunk_id, embedding FROM knowledge_chunk_embeddings WHERE chunk_id IN (\(placeholders))",
                arguments: StatementArguments(ids.map(\.uuidString))
            )
            var blobs: [UUID: Data] = [:]
            for row in rows {
                guard let raw: String = row["chunk_id"], let id = UUID(uuidString: raw),
                      let blob: Data = row["embedding"] else { continue }
                blobs[id] = blob
            }
            return blobs
        }
    }

    /// The non-memory kinds that share the document grounding budget. Memory is
    /// retrieved on its own lane (see `searchGrounding`) so short atomic facts
    /// are never crowded out of a single top-K by the larger document corpus.
    static let groundingDocumentKinds: Set<KnowledgeKind> = [.document, .call, .note]

    /// Two-lane grounding retrieval: documents and memories ranked + budgeted
    /// SEPARATELY, then concatenated for the caller to gate by kind.
    ///
    /// A single hybrid top-K over the WHOLE store let the document corpus crowd
    /// short memory facts out entirely (live 2026-06-13: "where am I based and
    /// what pet do I have" returned 5 document chunks, 0 memories — M1K3 fell
    /// back to persona chat and couldn't name the user's own city, while the
    /// tightly-phrased "what city does the user live in?" surfaced Cork at
    /// 0.728). Memories embed lower (5–40-token facts) and lose a shared budget
    /// the moment a query leans even slightly documentary. Giving each kind its
    /// own lane makes recall phrasing-robust.
    func searchGrounding(
        query: String,
        queryVector: [Float],
        documentLimit: Int = 5,
        memoryLimit: Int = 5
    ) throws -> [ChunkHit] {
        let documents = try searchHybrid(
            query: query, queryVector: queryVector,
            limit: documentLimit, kinds: Self.groundingDocumentKinds
        )
        let memories = try searchHybrid(
            query: query, queryVector: queryVector,
            limit: memoryLimit, kinds: [.memory]
        )
        return documents + memories
    }

    // MARK: - Row mapping

    private static func hit(from row: Row, chunkIDColumn: String = "chunk_id") -> ChunkHit? {
        guard let chunkRaw: String = row[chunkIDColumn],
              let chunkID = UUID(uuidString: chunkRaw),
              let itemRaw: String = row["item_id"],
              let itemID = UUID(uuidString: itemRaw)
        else { return nil }
        return ChunkHit(
            chunkID: chunkID,
            itemID: itemID,
            itemTitle: row["title"] ?? "",
            kind: KnowledgeKind(rawValue: row["kind"] ?? "note"),
            heading: row["heading"],
            content: row["content"] ?? "",
            createdAt: (row["item_created_at"] as Double?)
                .map(Date.init(timeIntervalSince1970:))
        )
    }

    // FTS MATCH-string construction lives in FTSQuery (shared with MemoryStore).
}

public enum KnowledgeStoreError: Error, Sendable, Equatable {
    case embeddingCountMismatch(chunks: Int, embeddings: Int)
}
