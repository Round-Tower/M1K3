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
    @AppStorage(AppEnvironment.contextBatteryEnabledKey) private var contextBattery = false
    @AppStorage(AppEnvironment.contextCalendarEnabledKey) private var contextCalendar = false
    @AppStorage(AppEnvironment.contextLocationEnabledKey) private var contextLocation = false
    @AppStorage(AppEnvironment.contextLocationPreciseKey) private var contextLocationPrecise = false
    @State private var calendarDenied = false
    @State private var locationDenied = false
    @State private var scriptRows: [AppEnvironment.ScriptRow] = []

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
            An approved script can be re-run later with different input, so \
            approve only scripts you trust with anything.
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
            Text("""
            Lets Claude (or another MCP client) on this Mac use M1K3's \
            knowledge search, voice, and mic. Loopback-only, one client at \
            a time. Connect with:

            claude mcp add --transport http m1k3 http://127.0.0.1:\(env.mcpHost.port)/mcp
            """)
            .font(.caption).foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
    }
}
