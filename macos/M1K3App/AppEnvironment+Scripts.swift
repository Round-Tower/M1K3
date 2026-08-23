//
//  AppEnvironment+Scripts.swift
//  M1K3App
//
//  The hands' app-side wiring (context-tools charter, first effectful tool):
//  the proposal inbox the propose_script tool posts into, the one-time
//  security-scoped grant for the Application Scripts folder (a sandboxed app
//  can RUN scripts there but cannot WRITE there without the user picking the
//  folder in an open panel — that panel IS the OS-level consent), install/
//  approve/revoke, and the rows the Privacy pane renders. Consent shape:
//  M1K3 drafts → the user reads the source → Install writes the file and pins
//  its SHA-256 in the approval ledger; delete the file or revoke and the hand
//  lets go.
//
//  Signed: Kev + claude-fable-5, 2026-08-23, Confidence 0.8 (panel/bookmark
//  flow is verify-at-⌘R; ledger + tool behaviour test-pinned in
//  M1K3AgentToolsTests). Prior: Unknown.

import AppKit
import CryptoKit
import Foundation
import M1K3AgentTools
import M1K3LogCore
import os

/// The proposal inbox — a standalone box (the ReviewModel init-order pattern:
/// the responder's callbacks capture the box, never a half-initialised self).
@MainActor @Observable final class ScriptProposalInbox {
    var pending: ScriptProposal?
}

/// Everything the script tools need, bundled so the palette builder's signature
/// stays readable. Passed ONLY by the interactive chat responder (the
/// delegate_deep precedent) — MCP's ask_m1k3, the menu-bar Ask, and the deep
/// delegation lane never see the hands.
struct ScriptExecutionHook {
    let runner: any ScriptRunning
    let approvals: any ScriptApprovalStoring
    let onPropose: @Sendable (ScriptProposal) -> Void

    /// For the persona-prefix warm: the SAME palette (only tool definitions
    /// render into the prefix), no live callbacks.
    static var forWarm: ScriptExecutionHook {
        // Definitions only render into the persona prefix — never execute — so
        // the warm hook carries inert stubs (Finding 9): even a mis-wired warm
        // that called execute() could not run or authorise anything.
        ScriptExecutionHook(
            runner: NullScriptRunning(),
            approvals: EmptyScriptApprovalStore(),
            onPropose: { _ in }
        )
    }
}

extension AppEnvironment {
    private static let scriptsLog = M1K3Log.logger(.scriptRun)
    nonisolated static let scriptsFolderBookmarkKey = "app.m1k3.scriptsFolderBookmark"

    /// One row for the Privacy pane's installed-scripts list.
    struct ScriptRow: Identifiable, Equatable {
        enum ApprovalState: Equatable {
            case approved
            case unapproved
            /// The file changed since approval — execute_script refuses it.
            case drifted
        }

        let script: InstalledScript
        let state: ApprovalState
        var id: String {
            script.name
        }
    }

    /// True when an install of `name` would overwrite a script already in the
    /// folder — so the review sheet can say so before the user commits (F4).
    func scriptExists(named name: String) async -> Bool {
        await UserScriptRunner().installedScripts().contains { $0.name == name }
    }

    func scriptRows() async -> [ScriptRow] {
        let approvals = KeychainScriptApprovalStore().approvals()
        return await UserScriptRunner().installedScripts().map { script in
            switch ScriptApprovalLedger.verdict(
                name: script.name, sha256: script.sha256, approvals: approvals
            ) {
            case .approved: ScriptRow(script: script, state: .approved)
            case .unknown: ScriptRow(script: script, state: .unapproved)
            case .drifted: ScriptRow(script: script, state: .drifted)
            }
        }
    }

    /// Approve the CURRENT bytes of an installed script (also heals drift —
    /// re-approving pins the new hash).
    func approveScript(_ script: InstalledScript) {
        KeychainScriptApprovalStore().record(
            ScriptApproval(name: script.name, sha256: script.sha256, approvedAt: Date())
        )
        Self.scriptsLog.notice(
            "script approved: \(script.name, privacy: .public) sha=\(String(script.sha256.prefix(12)), privacy: .public)"
        )
    }

    func revokeScriptApproval(named name: String) {
        KeychainScriptApprovalStore().revoke(name: name)
        Self.scriptsLog.notice("script approval revoked: \(name, privacy: .public)")
    }

    /// Reveal the scripts folder in Finder — reading needs no grant; the user
    /// can also drop hand-written scripts here and approve them in Settings.
    func revealScriptsFolder() {
        guard let dir = try? FileManager.default.url(
            for: .applicationScriptsDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    /// Install a proposed script. Returns nil on success, else a user-facing
    /// failure line for the sheet to show.
    func installProposedScript(_ proposal: ScriptProposal) -> String? {
        if let error = writeAndApproveProposedScript(proposal) { return error }
        // Plain Install: the sheet's work is done, dismiss it. (Install & Run
        // keeps the sheet up through the run and clears pending itself.)
        scriptProposals.pending = nil
        return nil
    }

    /// Write the script into the folder and pin its approval — WITHOUT clearing
    /// the pending proposal (so Install & Run can keep the review sheet, and its
    /// busy spinner, up through the run). Returns nil on success, else a
    /// user-facing failure line.
    private func writeAndApproveProposedScript(_ proposal: ScriptProposal) -> String? {
        guard ExecuteScriptTool.isValidScriptName(proposal.name) else {
            return "That script name isn't usable."
        }
        guard let folder = scriptsFolderForWriting() else {
            return "M1K3 needs access to its scripts folder to install — try again and click Grant Access."
        }
        let didAccess = folder.startAccessingSecurityScopedResource()
        defer { if didAccess { folder.stopAccessingSecurityScopedResource() } }
        let url = folder.appendingPathComponent(proposal.name)
        let data = Data(proposal.content.utf8)
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path
            )
        } catch {
            return "Couldn't write the script: \(error.localizedDescription)"
        }
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        KeychainScriptApprovalStore().record(
            ScriptApproval(name: proposal.name, sha256: sha, approvedAt: Date())
        )
        Self.scriptsLog.notice(
            "script installed+approved: \(proposal.name, privacy: .public) sha=\(String(sha.prefix(12)), privacy: .public)"
        )
        return nil
    }

    /// Install a proposed script AND run it immediately — the "Install & Run"
    /// path (Kev, 2026-08-23). The run fires HERE, from the user's click, via
    /// UserScriptRunner — deterministic, with none of the model's tool-calling
    /// in the loop. Output lands in the transcript display-only (never re-feeds
    /// the agent). Returns nil on success, else a user-facing failure line.
    /// Install failures return before any run.
    func installAndRunProposedScript(_ proposal: ScriptProposal) async -> String? {
        // Write + approve WITHOUT clearing pending — the sheet (and its
        // "Running…" spinner) must stay up through the run (review #2).
        if let installError = writeAndApproveProposedScript(proposal) {
            return installError
        }
        // writeAndApproveProposedScript recorded the approval under the exact bytes;
        // run through the same seam execute_script uses (folder-scoped,
        // hash-re-verified at the exec boundary).
        let runner = UserScriptRunner()
        let approvals = KeychainScriptApprovalStore().approvals()
        guard let approved = approvals.first(where: { $0.name == proposal.name }) else {
            return "Installed, but couldn't confirm the approval to run it."
        }
        let outcome: ScriptRunOutcome
        do {
            outcome = try await runner.run(
                named: proposal.name, arguments: [],
                timeout: ExecuteScriptTool.defaultTimeout, expectedSHA256: approved.sha256
            )
        } catch let ScriptRunFailure.launchFailed(reason) {
            // Pattern-match to surface the real reason — ScriptRunFailure isn't
            // LocalizedError, so `localizedDescription` would drop it (review #3).
            await chat.deliverScriptOutput(
                scriptName: proposal.name,
                output: "Couldn't launch: \(reason)", succeeded: false
            )
            scriptProposals.pending = nil
            return nil
        } catch {
            await chat.deliverScriptOutput(
                scriptName: proposal.name,
                output: "Couldn't launch: \(error.localizedDescription)", succeeded: false
            )
            scriptProposals.pending = nil
            return nil
        }
        let tail = ExecuteScriptTool.cappedTail(outcome.output)
        let disposition = ScriptRunDisposition(outcome)
        let body: String
        switch disposition {
        case .timedOut:
            body = "Timed out — it may still be running.\n\(tail)"
        case let .failed(reason):
            // Surface the failure reason like execute_script does, not just the tail.
            body = "\(reason)\n\(tail)"
        case .succeeded:
            body = tail
        }
        await chat.deliverScriptOutput(
            scriptName: proposal.name, output: body,
            succeeded: disposition == .succeeded
        )
        // The run is done — now dismiss the sheet (review #2).
        scriptProposals.pending = nil
        return nil
    }

    /// Delete an installed script and drop its approval.
    func uninstallScript(named name: String) -> String? {
        guard ExecuteScriptTool.isValidScriptName(name) else { return "Bad script name." }
        guard let folder = scriptsFolderForWriting() else {
            return "M1K3 needs access to its scripts folder — try again and click Grant Access."
        }
        let didAccess = folder.startAccessingSecurityScopedResource()
        defer { if didAccess { folder.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        } catch {
            return "Couldn't remove the script: \(error.localizedDescription)"
        }
        KeychainScriptApprovalStore().revoke(name: name)
        Self.scriptsLog.notice("script uninstalled: \(name, privacy: .public)")
        return nil
    }

    /// Resolve the stored security-scoped bookmark, or run the one-time panel
    /// aimed at the Application Scripts folder. Only THAT folder is accepted —
    /// granting anywhere else would put the write outside the sandbox's
    /// sanctioned door, so it is refused, not honoured.
    private func scriptsFolderForWriting() -> URL? {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.scriptsFolderBookmarkKey) {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data, options: [.withSecurityScope],
                relativeTo: nil, bookmarkDataIsStale: &stale
            ), !stale {
                return url
            }
        }
        guard let expected = try? FileManager.default.url(
            for: .applicationScriptsDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return nil }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = expected
        panel.prompt = "Grant Access"
        panel.message = "M1K3 installs approved scripts into this folder. Click Grant Access to allow it."
        guard panel.runModal() == .OK, let chosen = panel.url,
              chosen.standardizedFileURL.path == expected.standardizedFileURL.path
        else {
            Self.scriptsLog.notice("scripts folder grant declined or wrong folder")
            return nil
        }
        if let bookmark = try? chosen.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil
        ) {
            defaults.set(bookmark, forKey: Self.scriptsFolderBookmarkKey)
        }
        return chosen
    }
}
