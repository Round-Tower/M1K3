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

import SwiftUI

struct PrivacySettingsPane: View {
    @Environment(AppEnvironment.self) private var env
    @AppStorage(AppEnvironment.webSearchEnabledKey) private var webSearchEnabled = true
    @AppStorage(AppEnvironment.spotlightIndexingKey) private var spotlightIndexing = false

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

            mcpSection

            BrainAtHomeSection()
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
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
