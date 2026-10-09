//
//  GRDBCallPersistence.swift
//  M1K3Calls
//
//  GRDB-backed call store, mirroring KnowledgeStore's idiom (DatabaseQueue +
//  migrator, `path: nil` for an in-memory test store). Privacy-by-default: the
//  ONLY plaintext column is `started_at` (non-PII, needed to order the log) — the
//  title, transcript, speakers, and summaries all live inside the coder's `payload`
//  blob, which is AES-GCM ciphertext when an EncryptedCallCoder is used. So nothing
//  sensitive is readable in the database file.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.85,
//  Prior: internal knowledge-server project SemanticStore (GRDB idiom) + internal call-pipeline SQLiteCallPersistence (Kev).
//  Review: Kev + claude-opus-5-5, 2026-10-07 — `loadReadable` decodes row by row: a row the coder
//  rejects (`CallPersistenceError.decodingFailed`) is counted and skipped, any other error (the
//  key) throws. `loadAll` stays strict. Confidence 0.85.

import Foundation
import GRDB

public final class GRDBCallPersistence: CallPersistence, @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    private let coder: CallSessionCoder

    /// - Parameters:
    ///   - path: file path, or nil for an in-memory store (tests).
    ///   - coder: how sessions are serialised. Default plain JSON; pass an
    ///     `EncryptedCallCoder` for encryption at rest.
    public init(path: String? = nil, coder: CallSessionCoder = JSONCallCoder()) throws {
        dbQueue = try path.map { try DatabaseQueue(path: $0) } ?? DatabaseQueue()
        self.coder = coder
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "call_sessions") { t in
                t.column("id", .text).primaryKey()
                t.column("started_at", .double).notNull().indexed() // plaintext: ordering only
                t.column("payload", .blob).notNull() // everything sensitive, coder-encoded
            }
        }
        try migrator.migrate(dbQueue)
    }

    public func save(_ session: CallSession) throws {
        let payload = try coder.encode(session)
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO call_sessions (id, started_at, payload) VALUES (?, ?, ?)",
                arguments: [session.id.uuidString, session.startedAt.timeIntervalSince1970, payload]
            )
        }
    }

    public func load(id: UUID) throws -> CallSession? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT payload FROM call_sessions WHERE id = ?", arguments: [id.uuidString]
            ) else { return nil }
            let payload: Data = row["payload"]
            return try coder.decode(payload)
        }
    }

    public func loadAll() throws -> [CallSession] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT payload FROM call_sessions ORDER BY started_at DESC")
            return try rows.map { row in
                let payload: Data = row["payload"]
                return try coder.decode(payload)
            }
        }
    }

    public func loadReadable() throws -> CallLoadResult {
        let payloads = try dbQueue.read { db in
            try Data.fetchAll(db, sql: "SELECT payload FROM call_sessions ORDER BY started_at DESC")
        }
        var calls: [CallSession] = []
        var unreadable = 0
        for payload in payloads {
            do {
                try calls.append(coder.decode(payload))
            } catch CallPersistenceError.decodingFailed {
                unreadable += 1
            }
        }
        return CallLoadResult(calls: calls, unreadable: unreadable)
    }

    @discardableResult
    public func delete(id: UUID) throws -> Bool {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM call_sessions WHERE id = ?", arguments: [id.uuidString])
            return db.changesCount > 0
        }
    }

    /// Cheap count — never reads or decrypts a payload, just counts rows.
    public func count() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM call_sessions") ?? 0
        }
    }
}
