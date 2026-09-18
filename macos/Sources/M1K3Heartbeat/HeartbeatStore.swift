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
//  Review: Kev + claude-fable-5.1, 2026-09-07, Confidence 0.85 — Todos v1: `latestID()` — the row id a todo
//  proposed by this pulse records as its origin.
//  Review: Kev + claude-fable-5.1, 2026-09-18 — pulse-authored chips: `v3-chips` sidecar (`pulse_chips`, ordered by `position`, ON DELETE CASCADE
//  like the tags — Clear and the cap trim take them too), `record(chips:)`, one grouped `attachChips`, and `latestChips()` —
//  the NEWEST pulse only, so an older pulse's questions never stand in for a newer chipless one. Confidence 0.9.
//  Review: Kev + claude-fable-5.1, 2026-09-18 (4) — PR #382 second-pass fold: `latestPulseForCanvas()` returns the newest pulse's date AND chips from ONE transaction;
//  `latestChips()` is retired with its only caller (two reads could pair one pulse's age with another's questions). Confidence 0.9.
//  Review: Kev + claude-fable-5.1, 2026-09-18 (6) — PR #382, the two SUMMONED passes I had not read: `foreignKeysEnabled()` — the cascades rest on GRDB's default Configuration turning
//  foreign keys ON (raw SQLite ships them OFF); now pinned, so dropping it fails one test that names the cause. Confidence 0.9.

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
    /// The "ask me" chips this pulse authored for the next blank canvas
    /// (2026-09-18) — already through `PulseAskLine.admit`, in the order
    /// written. Empty for pre-chip rows and for every pulse that wrote none.
    public var chips: [String]

    public init(
        id: Int64, digest: String, narrative: String?, renderedBy: String,
        createdAt: Date, tags: Set<PulseTag> = [], chips: [String] = []
    ) {
        self.id = id
        self.digest = digest
        self.narrative = narrative
        self.renderedBy = renderedBy
        self.createdAt = createdAt
        self.tags = tags
        self.chips = chips
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
        // Pulse-authored chips (2026-09-18). Same cascade rule as the tags, for
        // the same reason: Clear and the cap trim take a pulse's chips with it.
        // `position` keeps the order written; the canvas rotates between them.
        migrator.registerMigration("v3-chips") { db in
            try db.create(table: "pulse_chips") { t in
                t.column("pulse_id", .integer).notNull().indexed()
                    .references("pulses", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.column("text", .text).notNull()
                t.primaryKey(["pulse_id", "position"])
            }
        }
        try migrator.migrate(dbQueue)
    }

    // MARK: - Write

    /// Record one pulse. Never throws — a write failure loses one pulse,
    /// never the app. `at:` is injectable for tests; the cap trims inside
    /// the same transaction so the store can never exceed it between writes
    /// (the FK cascade takes trimmed pulses' tags in the same breath).
    /// Returns the inserted row id (nil = the write failed) — a todo the
    /// pulse proposed records it as its origin, off the real insert rather
    /// than a second MAX(id) that only lines up when nothing failed.
    @discardableResult
    public func record(
        digest: String, narrative: String?, renderedBy: String,
        tags: Set<PulseTag> = [], chips: [String] = [], at date: Date = Date()
    ) -> Int64? {
        try? dbQueue.write { [capacity] db -> Int64 in
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
            for (position, chip) in chips.enumerated() {
                try db.execute(
                    sql: "INSERT INTO pulse_chips (pulse_id, position, text) VALUES (?, ?, ?)",
                    arguments: [pulseID, position, chip]
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
            return pulseID
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
            return try Self.attachChips(to: Self.attachTags(to: rows.map(Self.entry(from:)), db: db), db: db)
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
            return try Self.attachChips(to: Self.attachTags(to: rows.map(Self.entry(from:)), db: db), db: db)
        }
    }

    /// Total tag rows — the cascade tests' probe.
    func tagRowCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pulse_tags") ?? 0
        }
    }

    /// Whether SQLite is enforcing foreign keys on this store's queue. Raw SQLite
    /// ships with them OFF; GRDB's default `Configuration` turns them ON, and both
    /// sidecars' `ON DELETE CASCADE` — the "nothing survives Clear" guarantee —
    /// rest on that default. Pinned, so a future custom `Configuration` that drops
    /// it fails one test that names the cause (PR #382 review).
    func foreignKeysEnabled() throws -> Bool {
        try dbQueue.read { db in try Bool.fetchOne(db, sql: "PRAGMA foreign_keys") ?? false }
    }

    /// Total chip rows — the cascade tests' probe.
    func chipRowCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pulse_chips") ?? 0
        }
    }

    /// The blank canvas's ONE read: the newest pulse's date and its chips, from a
    /// single transaction. Two reads (`latestDate()`, then a separate chips query) left a
    /// window — tiny, pulses are hours apart, but real — in which a pulse landing
    /// between them paired a fresh age with an older pulse's questions, or the
    /// reverse (PR #382 second pass). nil = never pulsed.
    public func latestPulseForCanvas() throws -> (createdAt: Date, chips: [String])? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT id, created_at FROM pulses ORDER BY id DESC LIMIT 1")
            else { return nil }
            let pulseID: Int64 = row["id"] ?? 0
            let createdAt: Double = row["created_at"] ?? 0
            let chips = try String.fetchAll(
                db,
                sql: "SELECT text FROM pulse_chips WHERE pulse_id = ? ORDER BY position ASC",
                arguments: [pulseID]
            )
            return (Date(timeIntervalSince1970: createdAt), chips)
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

    /// The newest pulse's row id — what a todo proposed by that pulse's
    /// narrative records as its origin (TodoOrigin.pulseId).
    public func latestID() throws -> Int64? {
        try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM pulses")
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

    /// One grouped fetch for the batch's chips — never a query per pulse.
    private static func attachChips(to entries: [HeartbeatEntry], db: Database) throws -> [HeartbeatEntry] {
        guard !entries.isEmpty else { return entries }
        let ids = entries.map(\.id)
        let placeholders = databaseQuestionMarks(count: ids.count)
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT pulse_id, text FROM pulse_chips
            WHERE pulse_id IN (\(placeholders)) ORDER BY pulse_id, position
            """,
            arguments: StatementArguments(ids)
        )
        var byPulse: [Int64: [String]] = [:]
        for row in rows {
            let pulseID: Int64 = row["pulse_id"] ?? 0
            let text: String = row["text"] ?? ""
            byPulse[pulseID, default: []].append(text)
        }
        return entries.map { entry in
            var chipped = entry
            chipped.chips = byPulse[entry.id] ?? []
            return chipped
        }
    }
}
