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
//  Review: Kev + claude-opus-5, 2026-09-11, Confidence 0.85 — "Connect an
//  agent": the MCP footer's one hard-coded `claude mcp add` line becomes a
//  five-client picker over ConnectPlan.snippet (the SAME source the embedded
//  `m1k3` binary executes, so the screen and the tool cannot drift), each with
//  its destination and a Copy button, plus the Terminal one-liner pointing at
//  the CLI inside this very bundle. The footer keeps only the fact and the
//  guarantee — the picker makes the instructions redundant.
//

import AppKit // NSPasteboard — the Copy buttons
import M1K3AgentTools
import M1K3CLICore // ConnectPlan / MCPClient / MCPEndpoint — one source for the snippets
import SwiftUI

struct PrivacySettingsPane: View {
    @Environment(AppEnvironment.self) private var env
    @AppStorage(AppEnvironment.webSearchEnabledKey) private var webSearchEnabled = true
    @AppStorage(AppEnvironment.spotlightIndexingKey) private var spotlightIndexing = false
    @AppStorage(AppEnvironment.scriptToolsEnabledKey) private var scriptToolsEnabled = false
    @AppStorage(AppEnvironment.contextBatteryEnabledKey) private var contextBattery = false
    @AppStorage(AppEnvironment.contextCalendarEnabledKey) private var contextCalendar = false
    @AppStorage(AppEnvironment.contextLocationEnabledKey) private var contextLocation = false
    @AppStorage(AppEnvironment.contextLocationPreciseKey) private var contextLocationPrecise = false
    @State private var calendarDenied = false
    @State private var locationDenied = false
    @State private var scriptRows: [AppEnvironment.ScriptRow] = []
    @State private var connectClient: MCPClient = .claude

    var body: some View {
        Form {
            Section {
                Toggle("Web search (DuckDuckGo)", isOn: $webSearchEnabled)
            } header: {
                Text("Tools")
            } footer: {
                Text("""
                The one capability that sends anything off this Mac — every search \
                and page read shows in the reply as it happens. Date, time, and \
                system tools stay local either way.
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
                Text("""
                Puts your document and call titles — never contents or memories — \
                into Spotlight (⌘Space). Managed by macOS; turning off removes \
                everything M1K3 donated.
                """)
                .font(.caption).foregroundStyle(.secondary)
            }

            contextSection

            scriptsSection

            mcpSection

            BrainAtHomeSection()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// The context senses (context-tools charter): per-sense consent, all
    /// default OFF — off means the model can't see the tool. Toggle first,
    /// then macOS asks its own permission on first use; a system-level
    /// denial auto-reverts the toggle here with calm copy (charter fold —
    /// never a per-turn "permission denied" loop).
    private var contextSection: some View {
        Section {
            Toggle("Battery", isOn: $contextBattery)
            Toggle("Calendar (titles & times)", isOn: $contextCalendar)
            if calendarDenied {
                Text("macOS has calendar access off for M1K3 — grant it in System "
                    + "Settings → Privacy & Security → Calendars, then switch this "
                    + "back on.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Toggle("Location", isOn: $contextLocation)
            if contextLocation {
                Toggle("Precise location", isOn: $contextLocationPrecise)
            }
            if locationDenied {
                Text("macOS has location access off for M1K3 — grant it in System "
                    + "Settings → Privacy & Security → Location Services, then "
                    + "switch this back on.")
                    .font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Context")
        } footer: {
            Text("""
            Lets M1K3 ground answers in the moment — battery, your next \
            events, where you are (a coarse ~10 km area unless Precise is \
            on). Snapshots only: never remembered, never mixed with web \
            tools in a turn. macOS asks its own permission on first use.
            """)
            .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: "\(contextCalendar)-\(contextLocation)") { refreshContextAuth() }
    }

    private func refreshContextAuth() {
        if ContextSenseAuth.calendarDenied {
            calendarDenied = true
            contextCalendar = false
        } else {
            calendarDenied = false
        }
        if ContextSenseAuth.locationDenied {
            locationDenied = true
            contextLocation = false
        } else {
            locationDenied = false
        }
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
            Text("""
            M1K3's "hands" — it can only propose a script; every install and \
            approval is your click, and only the exact approved bytes ever run. \
            Script output can't reach the web tools in the same turn and never \
            becomes a remembered fact. An approved script can be re-run later \
            with different input, so approve only scripts you trust with anything.
            """)
            .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: scriptToolsEnabled) { await refreshScriptRows() }
    }

    private func refreshScriptRows() async {
        scriptRows = await env.scriptRows()
    }

    /// In-process MCP server controls, plus the per-client wiring.
    private var mcpSection: some View {
        Section {
            Toggle("MCP server (HTTP, localhost)", isOn: Binding(
                get: { env.mcpHost.isEnabled },
                set: { env.mcpHost.setEnabled($0) }
            ))
            if let status = env.mcpHost.statusText {
                LabeledContent("Status", value: status)
            }
            connectAnAgent
        } header: {
            Text("MCP server")
        } footer: {
            Text("""
            Lets an agent on this Mac use M1K3's knowledge, memory, voice, and \
            mic. Loopback-only, one client at a time.
            """)
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The snippet is `ConnectPlan.snippet` — the same source the `m1k3`
    /// binary executes, so what's on screen and what the CLI does can't drift.
    @ViewBuilder private var connectAnAgent: some View {
        Picker("Connect an agent", selection: $connectClient) {
            ForEach(MCPClient.allCases, id: \.self) { client in
                Text(client.displayName).tag(client)
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text(connectSnippet)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Text(ConnectPlan.destination(client: connectClient))
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { copyToPasteboard(connectSnippet) }
                    .controlSize(.small)
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Or from Terminal:").font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(terminalCommand)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button("Copy") { copyToPasteboard(terminalCommand) }
                    .controlSize(.small)
            }
        }
    }

    private var connectSnippet: String {
        ConnectPlan.snippet(client: connectClient, url: MCPEndpoint.url(port: env.mcpHost.port))
    }

    /// The CLI ships inside the bundle, so the path is always right — even for
    /// a copy of M1K3 the user dragged somewhere other than /Applications.
    private var terminalCommand: String {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/m1k3").path
        let quoted = path.contains(" ") ? "\"\(path)\"" : path
        return "\(quoted) connect \(connectClient.rawValue)"
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
