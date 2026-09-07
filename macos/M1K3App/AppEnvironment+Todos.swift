//
//  AppEnvironment+Todos.swift
//  M1K3App
//
//  The todo list's one write path. Every transition runs through
//  TodoConsentPolicy with the actor named — the user's taps resolve, the
//  resident's and visitors' proposals land PENDING, nothing else moves an
//  item. Store IO runs off the main actor (the ConstellationWindow rule);
//  `todosRevision` is the observable the screens and the grounding
//  snapshot re-read on.
//
//  The grounding snapshot: TodoGroundingBlock is rendered ONCE per write
//  and handed to the responder through a lock (the ReviewModel.liveContext
//  shape) — the responder's provider closure is @Sendable and must not
//  touch the store or the main actor per turn.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-07, Confidence 0.85 (the
//  policies and the block are package-TDD'd; this file is glue, verify at
//  ⌘R: propose over MCP → inbox → Accept → grounded answer). Prior: none
//  (new file).
//

import Foundation
import M1K3LogCore
import M1K3MCPKit
import M1K3Todos
import os

extension AppEnvironment {
    private static let todosLog = M1K3Log.logger(.todos)

    /// Consent for suggestions (Settings ▸ You ▸ Todos). Default ON — a
    /// suggestion is inert until accepted, and the inbox is the guard — the
    /// memoryAutoCaptureKey nil-or-true read.
    nonisolated static let todoSuggestionsKey = "todos.suggestions"

    nonisolated static func todoSuggestionsEnabled() -> Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: todoSuggestionsKey) == nil
            || defaults.bool(forKey: todoSuggestionsKey)
    }

    /// Visitors get a wider inbox than the resident (each caller is its own
    /// voice) but still a ceiling — an MCP client in a loop must not fill
    /// the list.
    nonisolated static let visitorPendingMax = 10

    /// The rendered OPEN TODOS block, or nil for none — read per turn by the
    /// responder, written by `refreshTodoGrounding()` after every change.
    nonisolated static let todoGroundingSnapshot = OSAllocatedUnfairLock<String?>(initialState: nil)

    // MARK: - The user's own actions

    func addTodo(title: String, note: String? = nil, due: Date? = nil) async {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let todo = Todo(
            title: trimmed, note: note, source: .user,
            state: TodoConsentPolicy.initialState(for: .user), due: due
        )
        await write("add") { store in try store.add(todo) }
    }

    func acceptTodo(_ todo: Todo) async {
        await transition(todo, .accept)
    }

    func completeTodo(_ todo: Todo) async {
        await transition(todo, .done)
    }

    func dismissTodo(_ todo: Todo) async {
        await transition(todo, .dismiss)
    }

    func reopenTodo(_ todo: Todo) async {
        await transition(todo, .reopen)
    }

    func clearResolvedTodos() async {
        await write("clear-resolved") { store in try store.clearResolved() }
    }

    private func transition(_ todo: Todo, _ transition: TodoTransition) async {
        guard let next = TodoConsentPolicy.resolve(transition, on: todo.state, by: .user) else {
            Self.todosLog.notice(
                "refused \(String(describing: transition), privacy: .public) on \(todo.state.rawValue, privacy: .public)"
            )
            return
        }
        await write("user \(transition)") { store in try store.setState(id: todo.id, next) }
    }

    // MARK: - Proposals (the resident's and visitors' one write)

    /// The heartbeat's proposal: already ceiling-checked at prompt time, but
    /// re-checked here — the pulse took a while and a visitor may have filled
    /// the inbox meanwhile. Silent on refusal (logged): the pulse itself is
    /// the user-facing artefact.
    func proposeTodoFromResident(title: String, origin: TodoOrigin?) async {
        guard let store = todoStore, Self.todoSuggestionsEnabled() else { return }
        let pending = await Task.detached(priority: .utility) {
            (try? store.pendingCount(source: .resident)) ?? 0
        }.value
        guard ProposalCeiling.mayPropose(pendingResidentCount: pending) else {
            Self.todosLog.notice("resident proposal refused: ceiling (\(pending, privacy: .public) pending)")
            return
        }
        let todo = Todo(
            title: title, source: .resident,
            state: TodoConsentPolicy.initialState(for: .resident), origin: origin
        )
        await write("resident proposal") { store in try store.add(todo) }
    }

    /// An MCP client's proposal. Stamped with its self-reported name (a
    /// label for the inbox, never trusted); lands pending or reads back why
    /// not.
    func proposeTodoFromVisitor(
        title: String, note: String?, due: Date?, clientName: String?
    ) async -> TodoProposeOutcome {
        guard let store = todoStore, Self.todoSuggestionsEnabled() else {
            Self.todosLog.notice("visitor proposal refused: suggestions off")
            return .disabled
        }
        let pending = await Task.detached(priority: .utility) {
            (try? store.pendingCount(source: .visitor)) ?? 0
        }.value
        guard pending < Self.visitorPendingMax else {
            Self.todosLog.notice("visitor proposal refused: ceiling (\(pending, privacy: .public) pending)")
            return .atCeiling
        }
        let source = TodoSource.visitor(clientName: clientName)
        let todo = Todo(
            title: title, note: note, source: source,
            state: TodoConsentPolicy.initialState(for: source), due: due
        )
        await write("visitor proposal") { store in try store.add(todo) }
        return .proposed(todo)
    }

    // MARK: - Plumbing

    /// One store write off the main actor, then the revision bump and the
    /// grounding re-render. Counts/kinds in the log, never a title.
    private func write(_ label: String, _ body: @escaping @Sendable (TodoStore) throws -> Void) async {
        guard let store = todoStore else { return }
        let ok = await Task.detached(priority: .utility) {
            do { try body(store); return true } catch { return false }
        }.value
        guard ok else {
            Self.todosLog.error("todo write failed: \(label, privacy: .public)")
            return
        }
        Self.todosLog.notice("todo write: \(label, privacy: .public)")
        await refreshTodoGrounding()
        todosRevision += 1
    }

    /// Re-render the OPEN TODOS block from the store. Called after every
    /// write and once at launch (the responder reads the snapshot only).
    func refreshTodoGrounding() async {
        guard let store = todoStore else { return }
        let block = await Task.detached(priority: .utility) {
            TodoGroundingBlock.render(open: (try? store.list(states: [.open])) ?? [], now: Date())
        }.value
        Self.todoGroundingSnapshot.withLock { $0 = block }
    }
}
