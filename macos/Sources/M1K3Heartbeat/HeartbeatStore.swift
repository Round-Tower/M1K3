//
//  HeartbeatStore.swift
//  M1K3Heartbeat
//
//  The pulse store — ConversationLogStore's idioms, deliberately: its own
//  DB file (heartbeat.sqlite, sibling to mcp-log.sqlite), GRDB DatabaseQueue
//  → @unchecked Sendable, nil path → in-memory for tests, cap-trim inside
//  the write transaction, one-tap Clear, EXCLUDED from diagnostics.
//
//  Privacy stance (the challenger's "a sequence of snapshots is a history"
//  finding, answered structurally):
//  1. Capped at ~a week of pulses (84 = 12/day × 7) — a rolling window,
//     never an archive.
//  2. `latestDate()` doubles as the schedule watermark, so clearing the
//     store also clears the cadence state — nothing survives Clear.
//  3. Pulses NEVER enter the chat transcript, so MemoryDistillation (which
//     only reads chat turns) can never mint permanent facts from them.
//     The app wiring owes the Time Machine exclusion xattr on the DB file.
//  4. record() never throws — best-effort, matching the house convention
//     for optional stores.
//
//  Signed: Kev + claude-fable-5, 2026-08-06, Confidence 0.9 (idioms proven
//  in ConversationLogStore; round-trip/cap/watermark/since pinned by tests;
//  the file-path wiring + backup-exclusion xattr are app-side, named there).
//  Prior: none (new file).
//  Review: Kev + claude-fable-5, 2026-08-30, Confidence 0.9 — pulse_tags
//  (v2 migration): structural tags per pulse, FK ON DELETE CASCADE so the
//  cap trim and Clear take the tags with them — the "nothing survives
//  Clear" guarantee gains no exception on its first extension. Cascade
//  pinned red-first.
//

import Foundation
import GRDB

/// One recorded pulse. `narrative` is nil when the model render was skipped
/// or failed NarrativeGuard — the digest is then the pulse. `renderedBy`
/// names the teller: a brain tier ("Big", "Lil") or "digest".
public struct HeartbeatEntry: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var digest: String
    public var narrative: String?
    public var renderedBy: String
    public var createdAt: Date
    /// Structural shape tags (2026-08-30) — composed by HeartbeatComposer,
    /// never content. Empty for pre-tag rows.
    public var tags: Set<PulseTag>

    public init(
        id: Int64, digest: String, narrative: String?, renderedBy: String,
        createdAt: Date, tags: Set<PulseTag> = []
    ) {
        self.id = id
        self.digest = digest
        self.narrative = narrative
        self.renderedBy = renderedBy
        self.createdAt = createdAt
        self.tags = tags
    }

    /// What the UI shows: the narrative when one passed the guard, else the
    /// digest.
    public var displayText: String {
        narrative ?? digest
    }
}

public final class HeartbeatStore: @unchecked Sendable {
    /// ~A week of 2-hourly pulses (12/day × 7) — a rolling window, not an
    /// archive.
    public static let defaultCapacity = 84

    private let dbQueue: DatabaseQueue
    private let capacity: Int

    /// `nil` path → in-memory store (tests).
    public init(path: String? = nil, capacity: Int = HeartbeatStore.defaultCapacity) throws {
        if let path {
            dbQueue = try DatabaseQueue(path: path)
        } else {
            dbQueue = try DatabaseQueue()
        }
        self.capacity = capacity
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "pulses") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("digest", .text).notNull()
                t.column("narrative", .text)
                t.column("rendered_by", .text).notNull()
                t.column("created_at", .double).notNull().indexed()
            }
        }
        // Structural tags (2026-08-30). ON DELETE CASCADE is load-bearing:
        // the store's "nothing survives Clear" guarantee must not acquire an
        // exception on its first extension — the cap trim and Clear take the
        // tags with them or the schema is wrong.
        migrator.registerMigration("v2-tags") { db in
            try db.create(table: "pulse_tags") { t in
                t.column("pulse_id", .integer).notNull().indexed()
                    .references("pulses", onDelete: .cascade)
                t.column("tag", .text).notNull()
                t.primaryKey(["pulse_id", "tag"])
            }
        }
        try migrator.migrate(dbQueue)
    }

    // MARK: - Write

    /// Record one pulse. Never throws — a write failure loses one pulse,
    /// never the app. `at:` is injectable for tests; the cap trims inside
    /// the same transaction so the store can never exceed it between writes
    /// (the FK cascade takes trimmed pulses' tags in the same breath).
    public func record(
        digest: String, narrative: String?, renderedBy: String,
        tags: Set<PulseTag> = [], at date: Date = Date()
    ) {
        try? dbQueue.write { [capacity] db in
            try db.execute(
                sql: """
                INSERT INTO pulses (digest, narrative, rendered_by, created_at)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [digest, narrative, renderedBy, date.timeIntervalSince1970]
            )
            let pulseID = db.lastInsertedRowID
            for tag in tags.sorted() {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO pulse_tags (pulse_id, tag) VALUES (?, ?)",
                    arguments: [pulseID, tag.rawValue]
                )
            }
            try db.execute(
                sql: """
                DELETE FROM pulses WHERE id NOT IN (
                    SELECT id FROM pulses ORDER BY id DESC LIMIT ?
                )
                """,
                arguments: [capacity]
            )
        }
    }

    // MARK: - Query

    /// Pulses newest-first — the list surface's data source.
    public func recent(limit: Int = HeartbeatStore.defaultCapacity) throws -> [HeartbeatEntry] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM pulses ORDER BY id DESC LIMIT ?",
                arguments: [limit]
            )
            return try Self.attachTags(to: rows.map(Self.entry(from:)), db: db)
        }
    }

    /// Pulses at or after `date`, OLDEST first — the day's arc, fed back
    /// into the next narrative render. SQL-side filter on the indexed
    /// column (the PR #94 lesson: never fetch-then-partition).
    public func since(_ date: Date) throws -> [HeartbeatEntry] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM pulses WHERE created_at >= ? ORDER BY id ASC",
                arguments: [date.timeIntervalSince1970]
            )
            return try Self.attachTags(to: rows.map(Self.entry(from:)), db: db)
        }
    }

    /// Total tag rows — the cascade tests' probe.
    func tagRowCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pulse_tags") ?? 0
        }
    }

    /// The newest pulse's timestamp — the schedule watermark. nil = never
    /// pulsed (or cleared), which the policy reads as due-now.
    public func latestDate() throws -> Date? {
        try dbQueue.read { db in
            try Double.fetchOne(db, sql: "SELECT MAX(created_at) FROM pulses")
                .map(Date.init(timeIntervalSince1970:))
        }
    }

    public func count() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pulses") ?? 0
        }
    }

    /// One-tap Clear — also resets the watermark (nothing survives).
    public func clear() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM pulses")
        }
    }

    // MARK: - Row mapping

    private static func entry(from row: Row) -> HeartbeatEntry {
        HeartbeatEntry(
            id: row["id"] ?? 0,
            digest: row["digest"] ?? "",
            narrative: row["narrative"],
            renderedBy: row["rendered_by"] ?? "digest",
            createdAt: Date(timeIntervalSince1970: row["created_at"] ?? 0)
        )
    }

    /// One grouped fetch for the batch's tags — never a query per pulse.
    private static func attachTags(to entries: [HeartbeatEntry], db: Database) throws -> [HeartbeatEntry] {
        guard !entries.isEmpty else { return entries }
        let ids = entries.map(\.id)
        let placeholders = databaseQuestionMarks(count: ids.count)
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT pulse_id, tag FROM pulse_tags WHERE pulse_id IN (\(placeholders))",
            arguments: StatementArguments(ids)
        )
        var byPulse: [Int64: Set<PulseTag>] = [:]
        for row in rows {
            let pulseID: Int64 = row["pulse_id"] ?? 0
            let tag: String = row["tag"] ?? ""
            byPulse[pulseID, default: []].insert(PulseTag(rawValue: tag))
        }
        return entries.map { entry in
            var tagged = entry
            tagged.tags = byPulse[entry.id] ?? []
            return tagged
        }
    }
}
