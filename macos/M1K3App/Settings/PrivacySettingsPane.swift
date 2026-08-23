//
//  PrivacySettingsPane.swift
//  M1K3App
//
//  The "Privacy" Settings tab: the product's promise told in one place — web
//  search (the one capability that sends anything off this Mac), Spotlight
//  donation, and the local MCP server. Split out of the old single-Form
//  SettingsView (2026-07-13) — see SettingsView.swift for the shell.
//
//  Signed: Kev + claude-fable-5, 2026-07-13, Confidence 0.85 (a straight move
//  — every footer/copy verbatim). Prior: Kev + claude-opus-4-8
//  (SettingsView.swift lineage, 2026-06-06).
//

import M1K3AgentTools
import SwiftUI

struct PrivacySettingsPane: View {
    @Environment(AppEnvironment.self) private var env
    @AppStorage(AppEnvironment.webSearchEnabledKey) private var webSearchEnabled = true
    @AppStorage(AppEnvironment.spotlightIndexingKey) private var spotlightIndexing = false
    @AppStorage(AppEnvironment.scriptToolsEnabledKey) private var scriptToolsEnabled = false
    @State private var scriptRows: [AppEnvironment.ScriptRow] = []

    var body: some View {
        Form {
            Section {
                Toggle("Web search (DuckDuckGo)", isOn: $webSearchEnabled)
            } header: {
                Text("Tools")
            } footer: {
                // Multiline literal (not a + chain): the SwiftUI ViewBuilder
                // type-checker times out on multi-segment String concatenation
                // (the PR #92 lesson) — backslash continuations keep it one line.
                Text("""
                M1K3 can search the web (DuckDuckGo) and read result pages \
                mid-answer. This is the one capability that sends anything off \
                this Mac — every search and page read is shown in the reply as \
                it happens. Date, time and system status tools stay fully local. \
                Off means the model can't see the web tools at all.
                """)
                .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Show documents & calls in Spotlight", isOn: $spotlightIndexing)
                    .onChange(of: spotlightIndexing) {
                        Task { await env.syncSpotlightIndex() }
                    }
            } header: {
                Text("Spotlight")
            } footer: {
                // Multiline literal, not a + chain (see the web-search footer above).
                Text("""
                Puts the titles of your imported documents and calls into \
                this Mac's Spotlight (⌘Space) search — never their contents, \
                and never your memories. The index is private to this Mac \
                and managed by macOS. Turning this off removes everything \
                M1K3 donated.
                """)
                .font(.caption).foregroundStyle(.secondary)
            }

            scriptsSection

            mcpSection

            BrainAtHomeSection()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// The hands: approved-scripts execution (context-tools charter, default
    /// OFF — off means the model never sees the tools).
    private var scriptsSection: some View {
        Section {
            Toggle("Run approved scripts", isOn: $scriptToolsEnabled)
            if scriptToolsEnabled {
                if scriptRows.isEmpty {
                    Text("No scripts installed yet — M1K3 can propose one in chat, or drop your own in the scripts folder and approve it here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(scriptRows) { row in
                    HStack {
                        Text(row.script.name).font(.system(.body, design: .monospaced))
                        Spacer()
                        switch row.state {
                        case .approved:
                            Text("Approved").font(.caption).foregroundStyle(.secondary)
                            Button("Revoke") {
                                env.revokeScriptApproval(named: row.script.name)
                                Task { await refreshScriptRows() }
                            }
                        case .unapproved:
                            Button("Approve") {
                                env.approveScript(row.script)
                                Task { await refreshScriptRows() }
                            }
                        case .drifted:
                            Text("Changed since approval").font(.caption).foregroundStyle(.orange)
                            Button("Re-approve") {
                                env.approveScript(row.script)
                                Task { await refreshScriptRows() }
                            }
                        }
                        Button("Uninstall", role: .destructive) {
                            _ = env.uninstallScript(named: row.script.name)
                            Task { await refreshScriptRows() }
                        }
                    }
                }
                Button("Open Scripts Folder…") { env.revealScriptsFolder() }
            }
        } header: {
            Text("Scripts")
        } footer: {
            // Multiline literal, not a + chain (the PR #92 type-checker lesson).
            Text("""
            Lets M1K3 run scripts you have installed and approved — its \
            "hands". M1K3 can only propose scripts; every install and \
            approval is your click, and only the exact approved bytes ever \
            run. Within a single turn, script output can't reach the web \
            tools (or vice versa), and it never becomes a remembered fact. \
            An approved script can still be re-run later with different \
            arguments, so approve only scripts whose behaviour you trust \
            with any input. Off means the model can't see these tools at all.
            """)
            .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: scriptToolsEnabled) { await refreshScriptRows() }
    }

    private func refreshScriptRows() async {
        scriptRows = await env.scriptRows()
    }

    /// In-process MCP server controls.
    private var mcpSection: some View {
        Section {
            Toggle("MCP server (HTTP, localhost)", isOn: Binding(
                get: { env.mcpHost.isEnabled },
                set: { env.mcpHost.setEnabled($0) }
            ))
            if let status = env.mcpHost.statusText {
                LabeledContent("Status", value: status)
            }
        } header: {
            Text("MCP server")
        } footer: {
            // Multiline literal, not a + chain (the PR #92 type-checker lesson).
            Text("""
            Lets Claude (or any MCP client) on THIS Mac use M1K3's knowledge \
            search, voice, and microphone. This server is loopback-only — \
            other machines can never reach it; the only network path into \
            M1K3 is Brain at Home below, for devices you pair, off by \
            default. One client at a time. Connect with:  claude mcp add \
            --transport http m1k3 http://127.0.0.1:\(env.mcpHost.port)/mcp
            """)
            .font(.caption).foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
    }
}
