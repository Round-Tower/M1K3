//
//  AgentLogWindow.swift
//  M1K3App
//
//  The Agent Interaction Log window: a scrollable review of every MCP tool
//  call (request + response) captured while the opt-in Settings toggle is on.
//  OFF by default — nothing is captured until the user flips "Log agent
//  conversations". Structurally mirrors HistoryView.swift (header row +
//  List + empty state) and ConstellationWindow.swift (the Window scene +
//  menu-command summon pattern).
//
//  Signed: Kev + claude-opus-4-8, 2026-07-05, Confidence 0.75 (compiles
//  against the tested ConversationLogStore; the window's look/feel + the
//  empty/off-state copy are Kev's ⌘R — verify-by-launch, not proven here).
//  Prior: none (new file).
//

import M1K3MCPLog
import SwiftUI

extension M1K3App {
    /// Stable id so the menu command summons (not respawns) the Agent Log window.
    static let agentLogWindowID = "agent-log"
}

/// The Agent Log window's content: a header (count + Clear) over a list of
/// captured calls, or an explanatory empty/off state. Live since 2026-08-19:
/// re-reads on `mcpLogRevision` (the stamping sink bumps it per captured
/// call), which retired the manual Refresh button.
struct AgentLogWindowContent: View {
    let env: AppEnvironment?
    @AppStorage(AppEnvironment.conversationLogEnabledKey) private var loggingEnabled = false
    @State private var calls: [LoggedMCPCall] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(minWidth: 520, minHeight: 480)
        .navigationTitle("Agent Log")
        .task(id: env?.mcpLogRevision ?? 0) { await refresh() }
    }

    private var header: some View {
        HStack {
            Label("Agent Log", systemImage: "bubble.left.and.bubble.right")
                .symbolRenderingMode(.hierarchical)
                .font(.pixelTitle)
            Text("\(calls.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) {
                clear()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(calls.isEmpty)
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if !loggingEnabled {
            ContentUnavailableView {
                Label("Logging is off", systemImage: "eye.slash")
            } description: {
                Text("M1K3 doesn't capture agent conversations by default. Turn on "
                    + "“Log agent conversations” in Settings → Advanced to review what a "
                    + "connected agent asks for and hears back — on this Mac only.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if calls.isEmpty {
            ContentUnavailableView {
                Label("No calls captured yet", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text("Logging is on. As a connected agent calls M1K3's tools, the "
                    + "requests and responses will appear here.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(calls) { call in
                    row(for: call)
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    private func row(for call: LoggedMCPCall) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(call.tool, systemImage: call.isError ? "exclamationmark.triangle.fill" : "wrench.and.screwdriver")
                    .font(.body.bold())
                    .foregroundStyle(call.isError ? .red : .primary)
                if let client = call.clientName {
                    Text(client)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(call.timestamp, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let argumentsJSON = call.argumentsJSON {
                Text(argumentsJSON)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Text(call.responseText)
                .font(.callout)
                .lineLimit(6)
                .textSelection(.enabled)
            Text("\(call.durationMS) ms")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private func refresh() async {
        guard let store = env?.conversationLog else { return }
        // Off the main actor — the sync read here was the documented
        // anti-pattern (HEARTBEAT_DESIGN.md §5); fixed with the live-refresh
        // change since the read now fires per captured call.
        calls = await Task.detached(priority: .utility) {
            (try? store.recent()) ?? []
        }.value
    }

    private func clear() {
        guard let store = env?.conversationLog else { return }
        try? store.clear()
        calls = []
    }
}

/// Adds "Agent Log" to the Window menu, mirroring ConstellationCommands.
struct AgentLogCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .windowList) {
            AgentLogMenuItem()
        }
    }
}

private struct AgentLogMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Agent Log") {
            openWindow(id: M1K3App.agentLogWindowID)
        }
    }
}
