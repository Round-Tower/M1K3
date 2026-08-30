//
//  ConversationLogStore.swift
//  M1K3MCPLog
//
//  The Agent Interaction Log store: an OPT-IN, OFF-BY-DEFAULT record of every
//  MCP tool call (request + response) that passes through M1K3's in-app HTTP
//  server, so the user can review what a visiting agent asked for and heard
//  back. Conforms to MCPCallLogSink (M1K3MCPKit) — the registry hands every
//  dispatch to this store when it's wired as the log sink; this store then
//  self-gates on the live `isEnabled` predicate, so flipping the Settings
//  toggle takes effect immediately with no server restart.
//
//  DESIGN (mirrors M1K3Memory.MemoryStore's idioms):
//
//  1. Separate DB file (mcp-log.sqlite), sibling to memory.sqlite — different
//     lifecycle (opt-in, one-tap Clear, excluded from diagnostics) from every
//     other store.
//  2. GRDB DatabaseQueue (internally serialized) → @unchecked Sendable, same
//     concurrency stance as MemoryStore/KnowledgeStore.
//  3. `nil` path → in-memory store, so tests never touch disk.
//  4. Arguments are the MCP `Value` type (Codable) — serialized to a JSON text
//     column rather than round-tripped back into `Value` on read: the UI only
//     ever needs to DISPLAY the request, never re-dispatch it, so a JSON
//     string is the simplest honest representation and keeps this target's
//     public surface free of the MCP module's types.
//  5. Capped at the newest N rows (default 500, per the privacy decision) —
//     trimmed on every write inside the same transaction as the insert.
//  6. `record(_:)` NEVER throws (the MCPCallLogSink contract is synchronous
//     and non-throwing) — a write failure is swallowed, same "best-effort,
//     inert-on-failure" stance AppEnvironment already takes opening MemoryStore.
//
//  Signed: Kev + claude-opus-4-8, 2026-07-05, Confidence 0.85 (idioms proven in
//  MemoryStore; TDD-pinned round-trip/cap/gate/clear behaviour; the live app
//  wiring — UserDefaults predicate + the sibling-file path — is verify-by-launch).
//  Prior: none (new file).
//  Review: claude-fable-5, 2026-08-19 — v2 migration adds nullable `client_name`
//  (untrusted display data from initialize clientInfo; old rows render as
//  "an agent"; migration test-pinned).
//

import Foundation
import GRDB
import M1K3MCPKit

/// One captured MCP call, read back for the Agent Log UI. Newest-first is the
/// query contract (`recent(limit:)`), not a property here.
public struct LoggedMCPCall: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var tool: String
    /// The request arguments, pretty-printable JSON text — nil when the call
    /// carried none (e.g. `get_status`). Never re-decoded into `Value`; the
    /// log is read-only.
    public var argumentsJSON: String?
    public var responseText: String
    public var isError: Bool
    public var durationMS: Int
    public var timestamp: Date
    /// The MCP client's self-reported name (initialize clientInfo) — nil for
    /// rows captured before v2 or sessions that never identified. Untrusted
    /// display data.
    public var clientName: String?

    public init(
        id: Int64,
        tool: String,
        argumentsJSON: String?,
        responseText: String,
        isError: Bool,
        durationMS: Int,
        timestamp: Date,
        clientName: String? = nil
    ) {
        self.id = id
        self.tool = tool
        self.argumentsJSON = argumentsJSON
        self.responseText = responseText
        self.isError = isError
        self.durationMS = durationMS
        self.timestamp = timestamp
        self.clientName = clientName
    }
}

/// GRDB-backed sink for the opt-in agent-interaction log.
public final class ConversationLogStore: MCPCallLogSink, @unchecked Sendable {
    /// Default cap — "keep the last 500" per the privacy decision. Overridable
    /// (test-only convenience) so the trim behaviour is pinnable without
    /// inserting 500+ rows.
    public static let defaultCapacity = 500

    private let dbQueue: DatabaseQueue
    private let capacity: Int
    /// Read live on every `record()` call — the app wires this to a
    /// UserDefaults read so flipping the Settings toggle takes effect with no
    /// server restart. Defaults to always-on so tests don't need to think
    /// about the gate unless they're testing it.
    private let isEnabled: @Sendable () -> Bool

    /// `nil` path → in-memory store (tests).
    public init(
        path: String? = nil,
        capacity: Int = ConversationLogStore.defaultCapacity,
        isEnabled: @escaping @Sendable () -> Bool = { true }
    ) throws {
        if let path {
            dbQueue = try DatabaseQueue(path: path)
        } else {
            dbQueue = try DatabaseQueue()
        }
        self.capacity = capacity
        self.isEnabled = isEnabled
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "mcp_calls") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("tool", .text).notNull()
                t.column("arguments_json", .text)
                t.column("response_text", .text).notNull()
                t.column("is_error", .boolean).notNull()
                t.column("duration_ms", .integer).notNull()
                t.column("created_at", .double).notNull().indexed()
            }
        }
        // v2 (2026-08-19): which client called — the interaction timeline
        // folds calls into per-client visits. Nullable: pre-v2 rows and
        // unidentified sessions render as "an agent".
        migrator.registerMigration("v2-client-name") { db in
            try db.alter(table: "mcp_calls") { t in
                t.add(column: "client_name", .text)
            }
        }
        try migrator.migrate(dbQueue)
    }

    // MARK: - MCPCallLogSink

    /// Record one MCP call. Self-gates on `isEnabled` — a false read (the
    /// toggle is off) is a true no-op, byte-identical to no sink being wired.
    /// Never throws: a write failure is swallowed (best-effort, matches the
    /// house convention for optional stores).
    public func record(_ entry: MCPCallLogEntry) {
        guard isEnabled() else { return }
        let argumentsJSON = entry.arguments.flatMap { args -> String? in
            guard let data = try? JSONEncoder().encode(args) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        try? dbQueue.write { [capacity] db in
            try db.execute(
                sql: """
                INSERT INTO mcp_calls
                    (tool, arguments_json, response_text, is_error, duration_ms, created_at, client_name)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    entry.tool, argumentsJSON, entry.responseText,
                    entry.isError, entry.durationMS, Date().timeIntervalSince1970,
                    entry.clientName,
                ]
            )
            // Trim to the newest `capacity` rows, in the same transaction as
            // the insert — the log can never exceed the cap between writes.
            try db.execute(
                sql: """
                DELETE FROM mcp_calls WHERE id NOT IN (
                    SELECT id FROM mcp_calls ORDER BY id DESC LIMIT ?
                )
                """,
                arguments: [capacity]
            )
        }
    }

    // MARK: - Query

    /// Captured calls, newest first — the Agent Log window's data source.
    public func recent(limit: Int = ConversationLogStore.defaultCapacity) throws -> [LoggedMCPCall] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM mcp_calls ORDER BY id DESC LIMIT ?",
                arguments: [limit]
            )
            return rows.map(Self.call(from:))
        }
    }

    /// Visiting-agent activity since a watermark, computed IN SQL — the
    /// heartbeat's read. Counting in Swift would page up to `capacity` rows
    /// of PII-bearing response text into memory to produce an integer;
    /// this touches only the tool-name column. Tool names come
    /// most-frequent first.
    public struct WindowedActivity: Sendable, Equatable {
        public let callCount: Int
        public let toolNames: [String]
        /// Distinct self-reported client identities in the window — identity,
        /// not content; feeds the heartbeat's `agent:<client>` pulse tags.
        public let clientNames: [String]

        public init(callCount: Int, toolNames: [String], clientNames: [String] = []) {
            self.callCount = callCount
            self.toolNames = toolNames
            self.clientNames = clientNames
        }
    }

    public func activity(since: Date) throws -> WindowedActivity {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT tool, COUNT(*) AS uses FROM mcp_calls
                WHERE created_at >= ?
                GROUP BY tool ORDER BY uses DESC, tool ASC
                """,
                arguments: [since.timeIntervalSince1970]
            )
            let counts = rows.map { (tool: $0["tool"] ?? "", uses: $0["uses"] ?? 0) as (String, Int) }
            let clients = try String.fetchAll(
                db,
                sql: """
                SELECT DISTINCT client_name FROM mcp_calls
                WHERE created_at >= ? AND client_name IS NOT NULL
                ORDER BY client_name ASC
                """,
                arguments: [since.timeIntervalSince1970]
            )
            return WindowedActivity(
                callCount: counts.reduce(0) { $0 + $1.1 },
                toolNames: counts.map(\.0),
                clientNames: clients
            )
        }
    }

    /// Total captured calls — the Settings/empty-state count.
    public func count() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mcp_calls") ?? 0
        }
    }

    /// One-tap Clear: hard-delete every captured call.
    public func clear() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM mcp_calls")
        }
    }

    // MARK: - Row mapping

    private static func call(from row: Row) -> LoggedMCPCall {
        LoggedMCPCall(
            id: row["id"] ?? 0,
            tool: row["tool"] ?? "",
            argumentsJSON: row["arguments_json"],
            responseText: row["response_text"] ?? "",
            isError: row["is_error"] ?? false,
            durationMS: row["duration_ms"] ?? 0,
            timestamp: Date(timeIntervalSince1970: row["created_at"] ?? 0),
            clientName: row["client_name"]
        )
    }
}
