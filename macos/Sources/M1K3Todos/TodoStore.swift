//
//  TodoStore.swift
//  M1K3Todos
//
//  HeartbeatStore's idioms, deliberately: its own DB file (todos.sqlite),
//  GRDB DatabaseQueue → @unchecked Sendable, nil path → in-memory for
//  tests. Unlike the pulse store this one is NOT capped — a todo is the
//  user's own list and never expires on its own; `clearResolved()` is the
//  one-tap tidy. The app owes the backup-exclusion xattr as for heartbeat.
//
//  Todos never enter the chat transcript, so MemoryDistillation cannot
//  mint permanent facts from them; they reach the model only through the
//  per-turn grounding block (TodoGroundingBlock).
//
//  Signed: Kev + claude-fable-5.1, 2026-09-07, Confidence 0.9 (round-trip,
//  filters, resolvedAt, per-source counts and clearResolved pinned against
//  the in-memory store). Prior: none (new file).
//

import Foundation
import GRDB

public final class TodoStore: @unchecked Sendable {
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
            try db.create(table: "todos") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("note", .text)
                t.column("source", .text).notNull().indexed()
                t.column("source_client", .text)
                t.column("state", .text).notNull().indexed()
                t.column("origin_memory_id", .text)
                t.column("origin_pulse_id", .integer)
                t.column("due", .double).indexed()
                t.column("created_at", .double).notNull().indexed()
                t.column("resolved_at", .double)
            }
        }
        try migrator.migrate(dbQueue)
    }

    // MARK: - Write

    public func add(_ todo: Todo) throws {
        try dbQueue.write { db in
            let (source, client) = Self.columns(for: todo.source)
            try db.execute(
                sql: """
                INSERT INTO todos (id, title, note, source, source_client, state,
                    origin_memory_id, origin_pulse_id, due, created_at, resolved_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    todo.id.uuidString, todo.title, todo.note, source, client, todo.state.rawValue,
                    todo.origin?.memoryId, todo.origin?.pulseId, todo.due?.timeIntervalSince1970,
                    todo.createdAt.timeIntervalSince1970, todo.resolvedAt?.timeIntervalSince1970,
                ]
            )
        }
    }

    /// Apply a state the consent policy already approved. Terminal states
    /// stamp `resolvedAt`; reopening clears it.
    public func setState(id: UUID, _ state: TodoState, at date: Date = Date()) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE todos SET state = ?, resolved_at = ? WHERE id = ?",
                arguments: [state.rawValue, state.isResolved ? date.timeIntervalSince1970 : nil, id.uuidString]
            )
        }
    }

    /// The one-tap tidy: done and dismissed go, open and pending stay.
    public func clearResolved() throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM todos WHERE state IN (?, ?)",
                arguments: [TodoState.done.rawValue, TodoState.dismissed.rawValue]
            )
        }
    }

    // MARK: - Read

    public func todo(id: UUID) throws -> Todo? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM todos WHERE id = ?", arguments: [id.uuidString])
                .map(Self.todo(from:))
        }
    }

    /// Newest first. An empty set lists nothing.
    public func list(states: Set<TodoState>) throws -> [Todo] {
        guard !states.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: states.count).joined(separator: ", ")
        return try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT * FROM todos WHERE state IN (\(marks)) ORDER BY created_at DESC, id DESC",
                arguments: StatementArguments(states.map(\.rawValue).sorted())
            ).map(Self.todo(from:))
        }
    }

    public func openCount() throws -> Int {
        try count(state: .open, source: nil)
    }

    /// What the ceiling reads.
    public func pendingCount(source: TodoSourceKind) throws -> Int {
        try count(state: .pending, source: source)
    }

    private func count(state: TodoState, source: TodoSourceKind?) throws -> Int {
        try dbQueue.read { db in
            if let source {
                return try Int.fetchOne(
                    db, sql: "SELECT COUNT(*) FROM todos WHERE state = ? AND source = ?",
                    arguments: [state.rawValue, source.rawValue]
                ) ?? 0
            }
            return try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM todos WHERE state = ?", arguments: [state.rawValue]
            ) ?? 0
        }
    }

    // MARK: - Mapping

    private static func columns(for source: TodoSource) -> (String, String?) {
        switch source {
        case .user, .resident: (source.kind.rawValue, nil)
        case let .visitor(clientName): (TodoSourceKind.visitor.rawValue, clientName)
        }
    }

    private static func todo(from row: Row) throws -> Todo {
        let kind = TodoSourceKind(rawValue: row["source"]) ?? .user
        let source: TodoSource = switch kind {
        case .user: .user
        case .resident: .resident
        case .visitor: .visitor(clientName: row["source_client"])
        }
        let memoryId: String? = row["origin_memory_id"]
        let pulseId: Int64? = row["origin_pulse_id"]
        let origin = (memoryId == nil && pulseId == nil) ? nil : TodoOrigin(memoryId: memoryId, pulseId: pulseId)
        let due: Double? = row["due"]
        let resolved: Double? = row["resolved_at"]
        let idString: String = row["id"]
        return Todo(
            id: UUID(uuidString: idString) ?? UUID(),
            title: row["title"], note: row["note"], source: source,
            state: TodoState(rawValue: row["state"]) ?? .open, origin: origin,
            due: due.map(Date.init(timeIntervalSince1970:)),
            createdAt: Date(timeIntervalSince1970: row["created_at"]),
            resolvedAt: resolved.map(Date.init(timeIntervalSince1970:))
        )
    }
}
