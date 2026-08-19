//
//  SidebarView.swift
//  M1K3App
//
//  The leading NavigationSplitView column: Chat, the workspace destinations
//  (Documents/Memories/Calls — echoes the iOS shell's TabSection("Workspace")
//  grouping), and a Conversations section that IS the old HistoryView's
//  content, migrated verbatim (title/relative-date rows, active checkmark,
//  swipe/context-menu delete, the historyRevision re-render trick). History
//  as a toolbar-button-behind-a-sheet made sense when the sidebar didn't
//  exist; once navigation is always visible, "browse past conversations" is
//  just what a sidebar's own row list already is on this platform (Mail's
//  mailbox list, Notes' folder list) — a 5th parallel destination would have
//  been redundant with it.
//
//  Destinations (which stay selected + swap the detail pane) live in the
//  scrolling List; app-ACTIONS that open their own window (Settings, Agent
//  Log) live in a pinned bottom `footer` so they never read as peers of the
//  destinations and never scroll off below a long conversation list.
//
//  No .glassBackdrop() here — .listStyle(.sidebar) already paints macOS's own
//  vibrant sidebar material; stacking our own NSVisualEffectView underneath
//  would double-blur and seam at the divider for no visual gain.
//
//  Signed: Kev + claude-fable-5, 2026-07-19, Confidence 0.85 (thin view over
//  tested session logic — ChatSession+Conversations.swift's API is unchanged;
//  layout/feel verify-at-⌘R, incl. the .hiddenTitleBar top-edge gotcha the
//  trailing .inspector already hit once). Prior: Unknown
//

import M1K3Chat
import SwiftUI

struct SidebarView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow
    @Binding var selection: SidebarSelection?

    var body: some View {
        List(selection: $selection) {
            Label("Chat", systemImage: "bubble.left.and.bubble.right")
                .tag(SidebarSelection.chat)

            // No header text (Kev's call) — the row icons/labels carry
            // enough meaning on their own without a "Workspace" caption.
            // These are true navigation DESTINATIONS (they stay selected +
            // swap the detail pane); the app-action items (Settings/Agent
            // Log — they open a separate window and never "stay selected")
            // live in the pinned footer below, so the two kinds don't read
            // as peers.
            Section {
                Label("Documents", systemImage: "books.vertical")
                    .tag(SidebarSelection.documents)
                Label("Memories", systemImage: "brain")
                    .tag(SidebarSelection.memories)
                Label("Calls", systemImage: "phone.bubble")
                    .tag(SidebarSelection.calls)
                // Promoted from the footer 2026-08-19: the Heartbeat became a
                // destination (timeline detail pane), which is precisely the
                // destination-vs-app-action line this file polices — it was on
                // the wrong side as a footer window-opener.
                Label("Heartbeat", systemImage: "waveform.path.ecg")
                    .tag(SidebarSelection.heartbeat)
            }

            Section("Conversations") {
                if summaries.isEmpty {
                    Text("No conversations yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(summaries) { summary in
                        conversationRow(for: summary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // NOTE: deliberately NOT .ignoresSafeArea(.container, edges: .top)
        // here, unlike the trailing .inspector — tried it (2026-07-19), and
        // unlike the inspector's bespoke ReviewPanel, this List's own first
        // ROW slid under the traffic lights (a NavigationSplitView sidebar's
        // vibrancy already extends to the window top on its own; the
        // inspector's fix doesn't transfer — that column has no built-in
        // material). Leaving safe-area respected keeps "Chat" clear of the
        // lights; the .sidebar list style already reads correctly to the edge.
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        // Drop the sidebar column's AUTOMATIC show/hide toggle — it lives in
        // the sidebar's own toolbar strip (grouped with New chat), reading as
        // part of the nav. ContentView puts a single toggle in the MAIN
        // window toolbar instead (always visible, incl. when collapsed), so
        // this auto one would just be a confusing duplicate. Removing it here
        // (inside the sidebar column) is what actually targets it — a removal
        // on the outer NavigationSplitView doesn't reach it.
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    env.chat.startNewConversation()
                    selection = .chat
                } label: {
                    Label("New chat", systemImage: "square.and.pencil")
                }
                .disabled(env.chat.messages.isEmpty || env.chat.isResponding)
                // ⌘N always reaches New chat even when the sidebar is
                // collapsed (narrow window) or its toolbar pencil is off-
                // screen — the input-bar pencil used to cover that, now
                // retired as a duplicate.
                .keyboardShortcut("n", modifiers: .command)
                .help("Start a fresh conversation — this one stays in Conversations (⌘N)")
            }
        }
    }

    /// App-action items pinned to the sidebar's bottom edge — Settings and
    /// Agent Log open their OWN window/scene (they never "stay selected"
    /// like a destination), so they don't belong in the scrolling
    /// destination list where they'd (a) read as peers of Documents/
    /// Memories/Calls and (b) get pushed off-screen below a long
    /// conversation list (Kev's actual complaint). A pinned footer keeps
    /// them one glance away, always. Review panel stays toolbar-only — it's
    /// a resizable inspector beside the chat, not something you launch.
    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                SettingsLink {
                    Image(systemName: "gearshape")
                        .imageScale(.large)
                }
                .help("M1K3 settings (⌘,)")
                .accessibilityLabel("Settings")

                Button {
                    openWindow(id: M1K3App.agentLogWindowID)
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .imageScale(.large)
                }
                .help("Agent Log — MCP tool calls captured from connected agents (opt-in)")
                .accessibilityLabel("Agent Log")

                Spacer()
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func conversationRow(for summary: ConversationSummary) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title ?? "New chat")
                    .font(.body)
                    .lineLimit(1)
                Text(summary.updatedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if summary.id == env.chat.activeConversationID {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .accessibilityLabel("Current conversation")
            }
        }
        .contentShape(Rectangle())
        .tag(SidebarSelection.conversation(summary.id))
        .disabled(env.chat.isResponding)
        .swipeActions {
            Button("Delete", role: .destructive) { env.chat.deleteConversation(summary.id) }
        }
        .contextMenu {
            Button("Delete", role: .destructive) { env.chat.deleteConversation(summary.id) }
        }
    }

    /// historyRevision is the observable invalidator — reading it here makes
    /// SwiftUI re-call conversationSummaries() after every save/title/delete.
    private var summaries: [ConversationSummary] {
        _ = env.chat.historyRevision
        return env.chat.conversationSummaries()
    }
}
