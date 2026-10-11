//
//  MCPServerSettingsPane.swift
//  M1K3App
//
//  The "MCP Server" Settings pane (1.1; Kev, TestFlight: the MCP server and Brain at Home
//  get their own headers): the in-app HTTP server toggle and status, the agent grants
//  (microphone, delete memories, open links), the access token, the per-client connect
//  snippets, and the Agent conversation log opt-in (which only ever concerned MCP).
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.8 (a straight move: copy and
//  behaviour verbatim; verify-by-launch as every SwiftUI move in this file family).
//  Prior: PrivacySettingsPane.swift (mcpSection, accessTokenRow, connectAnAgent and the
//  copy helpers; Kev + claude-opus-5 / claude-opus-5-5 lineage, see that file) and
//  AdvancedSettingsPane.swift (the Agent conversation log section).
//

import AppKit // NSPasteboard — the Copy buttons
import M1K3CLICore // ConnectPlan / MCPClient / MCPEndpoint — one source for the snippets
import M1K3Screengrab // the harness shows the shipped helper path, not the build's
import SwiftUI

struct MCPServerSettingsPane: View {
    @Environment(AppEnvironment.self) private var env
    @AppStorage(MCPHostController.grantMicrophoneKey) private var agentsUseMicrophone = false
    @AppStorage(MCPHostController.grantDeleteMemoriesKey) private var agentsDeleteMemories = false
    @AppStorage(MCPHostController.grantOpenLinksKey) private var agentsOpenLinks = false
    @AppStorage(AppEnvironment.conversationLogEnabledKey) private var conversationLogEnabled = false
    @State private var connectClient: MCPClient = .claude
    @State private var confirmingNewToken = false
    @State private var newTokenFailed = false

    var body: some View {
        Form {
            mcpSection

            conversationLogSection
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// The Agent Interaction Log opt-in: full MCP request+response text is
    /// captured only while this is on (default OFF).
    private var conversationLogSection: some View {
        Section {
            Toggle("Log agent conversations", isOn: $conversationLogEnabled)
            Button("Clear log", role: .destructive) {
                try? env.conversationLog?.clear()
            }
            .buttonStyle(.glass)
        } header: {
            SettingsHeader("Agent conversation log", systemImage: "list.bullet.rectangle")
        } footer: {
            Text("Off by default. When on, M1K3 keeps the last 500 tool calls a "
                + "connected agent makes — see them in Window → Agent Log, or the "
                + "Heartbeat timeline.")
                .font(.callout).foregroundStyle(.secondary)
        }
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
            Toggle("Let agents use the microphone", isOn: $agentsUseMicrophone)
            Toggle("Let agents delete memories", isOn: $agentsDeleteMemories)
            Toggle("Let agents open links on screen", isOn: $agentsOpenLinks)
            accessTokenRow
            connectAnAgent
        } header: {
            SettingsHeader("MCP server", systemImage: "network")
        } footer: {
            Text("""
            Lets an agent on this Mac use M1K3's knowledge, memory and voice. \
            Loopback-only, one client at a time. An agent needs the access token to connect. \
            Listening, deleting memories and opening links stay off until you allow them.
            """)
            .font(.callout).foregroundStyle(.secondary)
        }
        .onAppear { env.mcpHost.loadAccessToken() }
    }

    /// Shown masked; Copy is the only way to the whole token (#270).
    @ViewBuilder private var accessTokenRow: some View {
        LabeledContent("Access token") {
            HStack {
                if let token = env.mcpHost.accessToken {
                    Text(MCPAccessToken.masked(token))
                        .font(.system(.caption, design: .monospaced))
                    // Named on purpose: LabeledContent hands its label to every control
                    // inside, so VoiceOver read both of these as "Access token".
                    Button("Copy") { copySecret(token) }
                        .controlSize(.small)
                        .accessibilityLabel("Copy access token")
                    Button("New Token…") { confirmingNewToken = true }
                        .controlSize(.small)
                        .accessibilityLabel("New access token")
                } else {
                    Text("Unavailable — the Keychain couldn’t be read")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .confirmationDialog("Make a new access token?", isPresented: $confirmingNewToken) {
            Button("New Token", role: .destructive) { newTokenFailed = !env.mcpHost.rotateAccessToken() }
        } message: {
            Text("Every agent you’ve connected stops reaching M1K3 until you connect it again with the new token.")
        }
        if newTokenFailed {
            // Fails safe — the old token stays in force — but say so, or it looks like it worked.
            Text("Couldn’t save a new token to the Keychain. The current one still works.")
                .font(.callout).foregroundStyle(.secondary)
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
            Text(connectSnippet(token: env.mcpHost.accessToken.map(MCPAccessToken.masked) ?? "<access token>"))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Text(ConnectPlan.destination(client: connectClient))
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    if let token = env.mcpHost.accessToken { copySecret(connectSnippet(token: token)) }
                }
                .controlSize(.small)
                .disabled(env.mcpHost.accessToken == nil)
                .accessibilityLabel("Copy \(connectClient.displayName) setup")
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Or from Terminal — it asks for the token, so Copy that first:")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Text(terminalCommand)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button("Copy") { copyToPasteboard(terminalCommand) }
                    .controlSize(.small)
                    .accessibilityLabel("Copy Terminal command")
            }
        }
    }

    private func connectSnippet(token: String) -> String {
        ConnectPlan.snippet(client: connectClient, url: MCPEndpoint.url(port: env.mcpHost.port), token: token)
    }

    /// The CLI ships inside the bundle, so the path is always right — even for
    /// a copy of M1K3 the user dragged somewhere other than /Applications.
    private var terminalCommand: String {
        // Under the App Store screengrab harness the app runs from a scratch
        // DerivedData build, whose path would land in the frame — show the
        // path a real install has instead.
        let bundle = ScreengrabHarness.current.isActive
            ? URL(fileURLWithPath: "/Applications/M1K3.app") : Bundle.main.bundleURL
        let path = bundle.appendingPathComponent("Contents/Helpers/m1k3").path
        let quoted = path.contains(" ") ? "\"\(path)\"" : path
        return "\(quoted) login && \(quoted) connect \(connectClient.rawValue)"
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// A secret on the pasteboard, marked concealed (the nspasteboard.org
    /// convention) so clipboard managers and history tools skip it.
    private func copySecret(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
        pasteboard.setString(text, forType: .string)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    }
}
