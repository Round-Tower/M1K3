//
//  IssueReporter.swift
//  M1K3App
//
//  The secret-free "Report an issue" glue: gather recent app logs + environment,
//  scrub them (DiagnosticRedactor for paths/emails/name, then CanaryGuard for any
//  planted honeypots), copy the full report to the clipboard, and open GitHub's
//  prefilled new-issue page for the user to review and submit. No token, no
//  network call from the app itself — the user's browser does the filing.
//
//  The redaction/formatting/URL logic is the pure, unit-tested M1K3Diagnostics
//  core; this file is the OS-facing glue (OSLogStore, sysctl, pasteboard,
//  workspace) and is verified by launch.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-28, Confidence 0.8 (core TDD-pinned;
//  log capture + clipboard + open are verify-at-⌘R). Prior: Unknown.
//  Review: Kev + claude-fable-5, 2026-07-11 — buildReportBody's scrub+assembly
//  orchestration extracted to DiagnosticsReportBuilder (109-12 review nit); this
//  file now only gathers OS inputs and delegates. Behavior byte-identical; the
//  canary pass rides the builder's injected scrub seam. Confidence 0.9.
//  Review: Kev + claude-fable-5, 2026-07-30 (#86) — `metricDigests` param: the
//  caller (AdvancedSettingsPane) opts in and supplies
//  `env.recentMetricDigestLines()`; this file stays a pure pass-through —
//  never fetches MetricKit data itself. Empty by default (opt-out is the
//  no-op — nothing new ships unless the user asks).
//

import AppKit
import Darwin
import Foundation
import M1K3Chat
import M1K3Diagnostics
import OSLog

enum IssueReporter {
    /// The repo issues land in. Public new-issue page; the user is already signed
    /// in via their browser, so no app-side auth is needed.
    private static let repo = "Round-Tower/M1K3"

    /// Build the redacted report, stash the full body on the clipboard, and open
    /// the prefilled GitHub issue page. Returns whether the body was truncated in
    /// the URL (full text is on the clipboard either way) so the UI can hint.
    private static let issueTitle = "M1K3: issue report"

    /// Build the redacted report, stash the full body on the clipboard, and open
    /// the prefilled GitHub issue page. Returns whether the body was truncated in
    /// the URL (full text is on the clipboard either way) so the UI can hint.
    ///
    /// `OSLogStore.getEntries` + redaction can take hundreds of ms, so the whole
    /// report is built OFF the main actor; only the pasteboard write + open happen
    /// on main — tapping the button never hangs the UI.
    @discardableResult
    @MainActor
    static func reportIssue(
        whatHappened: String = "",
        activeBrain: String,
        userProfile: String?,
        metricDigests: [String] = []
    ) async -> Bool {
        let body = await Task.detached(priority: .userInitiated) {
            buildReportBody(
                whatHappened: whatHappened,
                activeBrain: activeBrain,
                userProfile: userProfile,
                metricDigests: metricDigests
            )
        }.value

        // Full (untruncated) body to the clipboard so nothing is lost to the URL cap.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)

        guard let built = GitHubIssueURL.newIssue(repo: repo, title: issueTitle, body: body) else {
            return false
        }
        NSWorkspace.shared.open(built.url)
        return built.truncated
    }

    /// Gather the OS-facing inputs (log store, bundle, sysctl, ProcessInfo) and
    /// delegate the scrub + assembly to the unit-pinned DiagnosticsReportBuilder
    /// (redact → canary scan → markdown; the honeypot pass rides the builder's
    /// scrub seam since CanaryGuard lives in M1K3Chat, not M1K3Diagnostics).
    private static func buildReportBody(
        whatHappened: String,
        activeBrain: String,
        userProfile: String?,
        metricDigests: [String]
    ) -> String {
        let report = IssueReport(
            title: issueTitle,
            whatHappened: whatHappened,
            appVersion: infoString("CFBundleShortVersionString"),
            build: infoString("CFBundleVersion"),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            device: deviceModel(),
            memoryGB: Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824),
            activeBrain: activeBrain,
            logs: recentLogs(), // raw — the builder owns redaction order
            metricDigests: metricDigests // already display-safe summary lines — never raw payload text
        )
        return DiagnosticsReportBuilder.build(
            report: report,
            homeDirectory: NSHomeDirectory(),
            userName: userProfile,
            scrubExtra: { CanaryGuard.fromLocalConfig().scan($0).text }
        )
    }

    /// Recent M1K3 log lines (last ~10 minutes, subsystem `app.m1k3`) from this
    /// process's own log store. Read-only, current-process scope → no special
    /// entitlement. Any failure degrades to a short note rather than throwing.
    private static func recentLogs(maxLines: Int = 200) -> String {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let start = store.position(date: Date().addingTimeInterval(-600))
            let entries = try store.getEntries(at: start)
                .compactMap { $0 as? OSLogEntryLog }
                .filter { $0.subsystem == "app.m1k3" }
            // Level-prioritized, not a blind tail: keep every error/fault so the
            // triggering failure can't scroll off behind a flood of .notice lines.
            let kept = DiagnosticLogPartition.select(entries, maxLines: maxLines) { entry in
                entry.level == .error || entry.level == .fault
            }
            return kept.map { "[\($0.category)] \($0.composedMessage)" }.joined(separator: "\n")
        } catch {
            return "(could not read logs: \(error.localizedDescription))"
        }
    }

    private static func infoString(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "?"
    }

    /// The Mac's hardware identifier (e.g. "Mac15,3"). Not PII — model, not serial.
    private static func deviceModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}
