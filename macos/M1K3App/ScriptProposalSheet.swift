//
//  ScriptProposalSheet.swift
//  M1K3App
//
//  The review half of the hands' consent ceremony: M1K3 proposed a script
//  (propose_script) and this sheet shows the user its full source before
//  anything exists on disk. Install writes it into the Application Scripts
//  folder (one-time grant panel on first use) and pins its hash in the
//  approval ledger; Not Now discards. The source is shown verbatim and
//  read-only — what you approve is byte-for-byte what can run.
//
//  Signed: Kev + claude-fable-5, 2026-08-23, Confidence 0.8 (layout
//  verify-at-⌘R; install path's ledger behaviour test-pinned). Prior: Unknown.

import M1K3AgentTools
import SwiftUI

struct ScriptProposalSheet: View {
    @Environment(AppEnvironment.self) private var env
    let proposal: ScriptProposal
    @State private var failure: String?
    @State private var replacesExisting = false
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("M1K3 proposes a script", systemImage: "hand.raised")
                .font(.headline)
            LabeledContent("Name", value: proposal.name)
            if !proposal.purpose.isEmpty {
                LabeledContent("Purpose", value: proposal.purpose)
            }
            ScrollView {
                Text(proposal.content)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(minHeight: 160, maxHeight: 280)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            Text("""
            Nothing runs until you install it. Installed scripts live in M1K3's \
            scripts folder, and only the exact bytes you approve can ever run — \
            if the file changes, M1K3 refuses until you re-approve.
            """)
            .font(.caption)
            .foregroundStyle(.secondary)
            if replacesExisting {
                Label(
                    "This replaces an existing script named \(proposal.name).",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption).foregroundStyle(.orange)
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Not Now") {
                    env.scriptProposals.pending = nil
                }
                .disabled(busy)
                Button("Install") {
                    failure = env.installProposedScript(proposal)
                }
                // Return maps to Install — the safe, non-executing action.
                // RUNNING a script must be a deliberate click, never the
                // reflexive default-key action (executing is its own consent —
                // the context-tools charter; review catch, 2026-08-23).
                .keyboardShortcut(.defaultAction)
                .disabled(busy)
                Button("Install & Run") {
                    busy = true
                    Task {
                        // The run fires from this click via the app, not the
                        // model — deterministic. Output lands in the transcript
                        // display-only (never re-feeds the agent).
                        let result = await env.installAndRunProposedScript(proposal)
                        busy = false
                        // installAndRunProposedScript clears `pending` itself on
                        // every completion (success + both launch-failure paths);
                        // only a write/approve failure returns a message with the
                        // sheet still up, so we just surface that.
                        if let result { failure = result }
                    }
                }
                .disabled(busy)
            }
            if busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Running \(proposal.name)…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        // A run keeps the sheet up: Escape / swipe-dismiss bypass the buttons'
        // .disabled(busy), so without this a user could close the sheet mid-run,
        // losing the "Running…" feedback while the (detached) script keeps going.
        // Executing is its own consent — don't let the surface vanish mid-execute
        // (review catch, 2026-08-24).
        .interactiveDismissDisabled(busy)
        .task(id: proposal.name) {
            replacesExisting = await env.scriptExists(named: proposal.name)
        }
    }
}
