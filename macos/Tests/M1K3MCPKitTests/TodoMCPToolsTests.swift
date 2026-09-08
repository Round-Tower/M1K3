//
//  TodoMCPToolsTests.swift
//  M1K3MCPKitTests
//
//  Pins the visitor's contract: list_todos reads, propose_todo PROPOSES
//  (pending, never open), every refusal reads back honestly, and the
//  surface has no tool that could move a todo.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-07, Confidence 0.9. Prior: none
//  (new file).
//

import Foundation
@testable import M1K3MCPKit
import M1K3Todos
import MCP
import Testing

struct TodoMCPToolsTests {
    private let now = Date(timeIntervalSince1970: 1_788_000_000)

    private func text(_ result: CallTool.Result) -> String? {
        if case let .text(text, _, _) = result.content.first { return text }
        return nil
    }

    private func registry(store: TodoStore, outcome: TodoProposeOutcome? = nil) -> MCPToolRegistry {
        let handlers = TodoToolHandlers(
            list: { states in try store.list(states: states) },
            propose: { title, note, due in
                if let outcome { return outcome }
                let todo = Todo(
                    title: title, note: note, source: .visitor(clientName: "Claude"),
                    state: TodoConsentPolicy.initialState(for: .visitor(clientName: "Claude")), due: due
                )
                try store.add(todo)
                return .proposed(todo)
            }
        )
        return MCPToolRegistry(makeTodoToolDefinitions(handlers: handlers, now: { now }))
    }

    @Test("the surface is list_todos and propose_todo — nothing that moves a todo")
    func surface() throws {
        let registry = try registry(store: TodoStore())
        #expect(registry.tools.map(\.name) == ["list_todos", "propose_todo"])
    }

    @Test("propose_todo files a PENDING todo stamped with the client, and says only the user can accept")
    func proposePending() async throws {
        let store = try TodoStore()
        let registry = registry(store: store)
        let result = await registry.call(
            name: "propose_todo",
            arguments: ["title": .string("Renew passport"), "note": .string("expires March"), "due": .string("2026-09-14")]
        )
        #expect(result.isError != true)
        #expect(text(result)?.contains("pending") == true)
        #expect(text(result)?.contains("Only the user can accept") == true)
        let pending = try store.list(states: [.pending])
        #expect(pending.count == 1)
        #expect(pending[0].source == .visitor(clientName: "Claude"))
        #expect(pending[0].note == "expires March")
        #expect(pending[0].due != nil)
        #expect(try store.openCount() == 0)
    }

    @Test("propose_todo reads the refusals back and writes nothing")
    func refusals() async throws {
        let store = try TodoStore()
        let off = await registry(store: store, outcome: .disabled)
            .call(name: "propose_todo", arguments: ["title": .string("x")])
        #expect(text(off)?.contains("turned suggestions off") == true)
        let full = await registry(store: store, outcome: .atCeiling)
            .call(name: "propose_todo", arguments: ["title": .string("x")])
        #expect(text(full)?.contains("Nothing was written") == true)
        #expect(try store.list(states: Set(TodoState.allCases)).isEmpty)
    }

    @Test("an empty title or a bad due date is an isError")
    func badInput() async throws {
        let registry = try registry(store: TodoStore())
        let blank = await registry.call(name: "propose_todo", arguments: ["title": .string("  ")])
        #expect(blank.isError == true)
        let due = await registry.call(name: "propose_todo", arguments: ["title": .string("x"), "due": .string("next tuesday")])
        #expect(due.isError == true)
    }

    @Test("list_todos formats state, due band and source; defaults to open; empty says so")
    func list() async throws {
        let store = try TodoStore()
        let registry = registry(store: store)
        let empty = await registry.call(name: "list_todos", arguments: [:])
        #expect(text(empty) == "No todos.")
        try store.add(Todo(title: "Call Mum", source: .user, state: .open, createdAt: now))
        try store.add(Todo(
            title: "Renew passport", source: .visitor(clientName: "Claude"), state: .pending,
            due: now.addingTimeInterval(3 * 86400), createdAt: now
        ))
        try store.add(Todo(title: "Water plants", source: .resident, state: .pending, createdAt: now))
        let open = try #require(text(await registry.call(name: "list_todos", arguments: [:])))
        #expect(open == "1. Call Mum — open")
        let pending = try #require(text(await registry.call(name: "list_todos", arguments: ["state": .string("pending")])))
        #expect(pending.contains("Renew passport — pending, due in 3 days (from Claude)"))
        #expect(pending.contains("Water plants — pending (suggested by M1K3)"))
        let bad = await registry.call(name: "list_todos", arguments: ["state": .string("later")])
        #expect(bad.isError == true)
    }
}
