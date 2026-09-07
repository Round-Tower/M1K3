//
//  TodoMCPTools.swift
//  M1K3MCPKit
//
//  The visitor's door onto the todo list: `list_todos` reads it,
//  `propose_todo` PROPOSES onto it — a pending item the user accepts or
//  dismisses with one tap. No MCP tool can open, close, or edit a todo:
//  TodoConsentPolicy hands every non-user transition a nil, and this file
//  simply never asks. The app supplies the handlers (store, ceiling,
//  toggle, the caller's client name); this package only formats.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-07, Confidence 0.9 (surface,
//  outcomes, due parsing and the propose-only contract pinned by
//  TodoMCPToolsTests; the store/ceiling wiring is app glue). Prior: none
//  (new file).
//

import Foundation
import M1K3Todos
import MCP

public struct MCPTodoError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) {
        self.description = description
    }
}

/// What `propose_todo` did — every branch reads honestly back to the caller.
public enum TodoProposeOutcome: Sendable, Equatable {
    /// Filed as PENDING (never open) — the returned todo is what was stored.
    case proposed(Todo)
    /// Too many unanswered proposals already; nothing written.
    case atCeiling
    /// The user turned suggestions off; nothing written.
    case disabled
}

public struct TodoToolHandlers: Sendable {
    /// The todos in the given states, newest first.
    public var list: @Sendable (_ states: Set<TodoState>) async throws -> [Todo]
    /// File a visitor proposal (the app stamps the client name and applies
    /// its ceiling + toggle).
    public var propose: @Sendable (_ title: String, _ note: String?, _ due: Date?) async throws -> TodoProposeOutcome

    public init(
        list: @escaping @Sendable (_ states: Set<TodoState>) async throws -> [Todo],
        propose: @escaping @Sendable (_ title: String, _ note: String?, _ due: Date?) async throws -> TodoProposeOutcome
    ) {
        self.list = list
        self.propose = propose
    }
}

public func makeTodoToolDefinitions(handlers: TodoToolHandlers, now: @escaping @Sendable () -> Date = { Date() })
    -> [MCPToolDefinition]
{
    [
        MCPToolDefinition(
            tool: Tool(
                name: "list_todos",
                description: "The user's todo list as M1K3 holds it. `open` (default) is what is on the list; "
                    + "`pending` is what M1K3 or a visiting agent has proposed and the user has not yet "
                    + "accepted; `all` includes done and dismissed. Read-only.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "state": [
                            "type": "string", "enum": ["open", "pending", "all"],
                            "description": "which items to list (default open)",
                        ],
                    ],
                ]
            ),
            handler: { args in
                let states: Set<TodoState> = switch stringArg(args, "state") ?? "open" {
                case "open": [.open]
                case "pending": [.pending]
                case "all": Set(TodoState.allCases)
                default: throw MCPTodoError("list_todos: state must be open, pending, or all")
                }
                let todos = try await handlers.list(states)
                return formatTodoList(todos, now: now())
            }
        ),
        MCPToolDefinition(
            tool: Tool(
                name: "propose_todo",
                description: "PROPOSE a todo for the user. It lands in their inbox as pending, stamped with "
                    + "your client name; only the user can accept, complete, or dismiss it. This never "
                    + "opens a todo, never marks anything done, and is refused when the user has turned "
                    + "suggestions off or the inbox is full. Use it for something the user said they "
                    + "still need to do — not for your own work.",
                inputSchema: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "the task, in the user's terms, one line"],
                        "note": ["type": "string", "description": "optional context — why, or where it came from"],
                        "due": [
                            "type": "string",
                            "description": "optional ISO-8601 date (2026-09-14) or date-time",
                        ],
                    ],
                    "required": ["title"],
                ]
            ),
            handler: { args in
                let title = stringArg(args, "title")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !title.isEmpty else { throw MCPTodoError("propose_todo requires a non-empty title") }
                guard title.count <= TodoProposalLine.maxTitleLength else {
                    throw MCPTodoError("propose_todo: title is over \(TodoProposalLine.maxTitleLength) characters")
                }
                let note = stringArg(args, "note")?.trimmingCharacters(in: .whitespacesAndNewlines)
                var due: Date?
                if let raw = stringArg(args, "due")?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
                    guard let parsed = parseDue(raw) else {
                        throw MCPTodoError("propose_todo: due must be an ISO-8601 date or date-time")
                    }
                    due = parsed
                }
                switch try await handlers.propose(title, note?.isEmpty == true ? nil : note, due) {
                case let .proposed(todo):
                    return "Proposed “\(todo.title)” — pending in the user's inbox. Only the user can accept or close it."
                case .atCeiling:
                    return "Not proposed: the inbox already holds unanswered proposals. Nothing was written."
                case .disabled:
                    return "Not proposed: the user has turned suggestions off. Nothing was written."
                }
            }
        ),
    ]
}

/// `2026-09-14` → local midnight that day; otherwise a full ISO-8601
/// date-time. Anything else is nil (the tool refuses rather than guesses).
func parseDue(_ raw: String) -> Date? {
    if let full = ISO8601DateFormatter().date(from: raw) { return full }
    let dayOnly = ISO8601DateFormatter()
    dayOnly.formatOptions = [.withFullDate, .withDashSeparatorInDate]
    dayOnly.timeZone = .current
    return dayOnly.date(from: raw)
}

func formatTodoList(_ todos: [Todo], now: Date) -> String {
    guard !todos.isEmpty else { return "No todos." }
    let lines = todos.enumerated().map { index, todo -> String in
        var line = "\(index + 1). \(todo.title) — \(todo.state.rawValue)"
        if let due = todo.due { line += ", \(TodoGroundingBlock.dueBand(due, now: now))" }
        if case let .visitor(clientName) = todo.source { line += " (from \(clientName ?? "an unnamed agent"))" }
        if todo.source.kind == .resident { line += " (suggested by M1K3)" }
        if let note = todo.note, !note.isEmpty { line += "\n   \(note)" }
        return line
    }
    return lines.joined(separator: "\n")
}
