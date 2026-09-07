//
//  TodosScreen.swift
//  M1K3
//
//  The todo list's canonical surface — a sidebar destination beside the
//  Heartbeat. Three strips: the inbox (what M1K3 or a visiting agent
//  proposed — Accept or Dismiss, one tap each), the open list (Done), and
//  a fold of what's resolved (Reopen / Clear). Adding is a single field.
//  Store reads run OFF the main actor; every write goes through
//  AppEnvironment+Todos, so this view can't move an item on its own.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-07, Confidence 0.8 (mirrors
//  HeartbeatScreen's idioms; the rendered feel is ⌘R verify-owed).
//  Prior: none (new file).
//

import M1K3Todos
import SwiftUI

struct TodosScreen: View {
    let env: AppEnvironment?

    @State private var pending: [Todo] = []
    @State private var open: [Todo] = []
    @State private var resolved: [Todo] = []
    @State private var draft = ""
    @State private var showResolved = false

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .navigationTitle("Todos")
        .task(id: env?.todosRevision ?? 0) { await refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Todos", systemImage: "checklist")
                    .symbolRenderingMode(.hierarchical)
                    .font(.pixelTitle)
                Text("\(open.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack {
                TextField("Add a todo", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add() }
                Button("Add") { add() }
                    .buttonStyle(.glass)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if env?.todoStore == nil {
            ContentUnavailableView {
                Label("Todos are unavailable", systemImage: "checklist")
            } description: {
                Text("The list couldn't be opened on this Mac.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if pending.isEmpty, open.isEmpty, resolved.isEmpty {
            ContentUnavailableView {
                Label("Nothing on the list", systemImage: "checklist")
            } description: {
                Text("Add one above. M1K3 and connected agents can suggest todos; "
                    + "suggestions wait here for your say-so.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if !pending.isEmpty {
                    Section {
                        ForEach(pending) { todo in pendingRow(todo) }
                    } header: {
                        Label("Suggested — yours to accept", systemImage: "tray")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !open.isEmpty {
                    Section {
                        ForEach(open) { todo in openRow(todo) }
                    } header: {
                        Label("Open", systemImage: "circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !resolved.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showResolved) {
                            ForEach(resolved) { todo in resolvedRow(todo) }
                            Button("Clear resolved", role: .destructive) {
                                Task { await env?.clearResolvedTodos() }
                            }
                            .font(.caption)
                        } label: {
                            Label("Resolved (\(resolved.count))", systemImage: "checkmark.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: - Rows

    private func pendingRow(_ todo: Todo) -> some View {
        HStack(alignment: .firstTextBaseline) {
            titleBlock(todo)
            Spacer()
            Button("Accept") { Task { await env?.acceptTodo(todo) } }
                .buttonStyle(.glass)
            Button("Dismiss", role: .destructive) { Task { await env?.dismissTodo(todo) } }
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 2)
    }

    private func openRow(_ todo: Todo) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Button {
                Task { await env?.completeTodo(todo) }
            } label: {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Done")
            titleBlock(todo)
            Spacer()
            Button("Dismiss", role: .destructive) { Task { await env?.dismissTodo(todo) } }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    private func resolvedRow(_ todo: Todo) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: todo.state == .done ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(.tertiary)
            Text(todo.title)
                .strikethrough(todo.state == .done)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Reopen") { Task { await env?.reopenTodo(todo) } }
                .buttonStyle(.plain)
                .font(.caption)
        }
    }

    private func titleBlock(_ todo: Todo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(todo.title)
                .textSelection(.enabled)
            if let detail = detailLine(todo) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(todo.isOverdue(now: Date()) ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
        }
    }

    /// Source + due, only when there is something to say.
    private func detailLine(_ todo: Todo) -> String? {
        var parts: [String] = []
        switch todo.source {
        case .user: break
        case .resident: parts.append("suggested by M1K3")
        case let .visitor(name): parts.append("from \(name ?? "a paired device")")
        }
        if let due = todo.due { parts.append(TodoGroundingBlock.dueBand(due, now: Date())) }
        if let note = todo.note, !note.isEmpty { parts.append(note) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Actions

    private func add() {
        let title = draft
        draft = ""
        Task { await env?.addTodo(title: title) }
    }

    private func refresh() async {
        guard let store = env?.todoStore else { return }
        let (p, o, r) = await Task.detached(priority: .utility) {
            (
                (try? store.list(states: [.pending])) ?? [],
                (try? store.list(states: [.open])) ?? [],
                (try? store.list(states: [.done, .dismissed])) ?? []
            )
        }.value
        pending = p
        open = o
        resolved = r
    }
}
