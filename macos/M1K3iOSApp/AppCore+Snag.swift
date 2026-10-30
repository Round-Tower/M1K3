//
//  AppCore+Snag.swift
//  M1K3iOS
//
//  #750, the iPhone and iPad half: the last session didn't close cleanly. The guard is marked
//  while the scene is active and cleared on a trip to the background, because iOS may end a
//  backgrounded app at any time and that is no snag. A mark still standing at the next active
//  launch is a crash, an out-of-memory kill (the likely failure here, MLX under memory pressure,
//  which MetricKit never reports as a crash) or a force-quit from the foreground. A snag holds
//  the rating ask for three days, whatever the age band; the one-time offer (SnagNoteHost) is
//  shown only to the bands #708's offer is shown to, and lives for this session only.
//
//  App glue: the rule is SessionGuard's and SnagReport's, unit-pinned in M1K3Diagnostics;
//  SnagNoteScanTests pins this wiring.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-29, Confidence 0.7 (verify-by-launch owed: a crash
//  from the foreground shows the card; a swipe-away from the app switcher does not).
//  Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-29 (pre-push review fold) — the guard moved to the app struct
//  (M1K3iOSHarnessApp), which marks before AppCore builds; this keeps the note, the ledger feed and the
//  draft. A swipe-away from the switcher reaches .background first (a review agent's Simulator run on
//  iOS 27), so it clears the mark. Confidence 0.75.
//

import Foundation
import M1K3Chat
import M1K3Diagnostics
import M1K3Screengrab
import OSLog
import UIKit

/// One snag report waiting on the sheet (`.sheet(item:)` needs an identity).
struct SnagDraft: Identifiable {
    let id = UUID()
    /// What the sheet says above the text: the whole of what goes, and how.
    let intro: String
    /// Brain, version and system only.
    let subject: String
    /// The exact, already-redacted text the user sees, edits and sends.
    let body: String
}

extension AppCore {
    /// Reads and writes nothing under the screengrab harness, or in a Debug build unless
    /// `-armSessionGuard YES` is passed (Xcode's Stop is not a snag).
    nonisolated static var sessionGuardInert: Bool {
        if ScreengrabHarness.current.isActive { return true }
        #if DEBUG
            return !UserDefaults.standard.bool(forKey: "armSessionGuard")
        #else
            return false
        #endif
    }

    /// The previous session began at `openedAt` and never closed (the app struct's SessionGuard
    /// says so): hold the rating ask, and raise the offer for the chat screen.
    func noteUncleanExit(openedAt: Date, now: Date = Date()) {
        reviewLedger.recordCrash(at: now)
        snag = SnagNote(openedAt: openedAt, noticedAt: now)
        Logger(subsystem: "app.m1k3", category: "launch")
            .notice("session: the last one didn't close cleanly (began \(openedAt, privacy: .public))")
    }

    /// The redacted report for the sheet: SnagReportFormatter's scrub, then the canary pass,
    /// as on the Mac. The phone has no display name to redact.
    func snagDraft(_ note: SnagNote) -> SnagDraft {
        let device = UIDevice.current
        let report = SnagReport(
            openedAt: note.openedAt,
            noticedAt: note.noticedAt,
            brain: answeringBrainName,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            system: "\(device.systemName) \(device.systemVersion)",
            crashLines: MobileMetricKitCollector.shared.recentCrashLines()
        )
        let body = SnagReportFormatter.redactedBody(
            report,
            homeDirectory: NSHomeDirectory(),
            userName: nil,
            scrubExtra: { CanaryGuard.fromLocalConfig().scan($0).text }
        )
        return SnagDraft(
            intro: String(localized: """
            This is the whole message: that M1K3 didn't close cleanly last time, when that session began, \
            the brain, the app and system versions, and any crash summaries this device kept. Nothing you \
            typed or said goes with it. It goes to \(RoundTowerReports.recipient) from your own mail app, \
            which opens with it filled in. M1K3 sends nothing itself. Round Tower reads it to find what went \
            wrong, and deletes it if you ask. If you remember what you were doing, add it at the end: that \
            helps most.
            """),
            subject: SnagReportFormatter.subject(report),
            body: body
        )
    }

    /// The redacted report for a brain that won't get ready. The log goes through the formatter's
    /// category gate, then the same scrub as a snag. `shown` is the line the chat showed.
    func brainFailureDraft(shown: String) async -> SnagDraft {
        let device = UIDevice.current
        let entries = await Task.detached(priority: .userInitiated) { Self.recentLogEntries() }.value
        let report = BrainFailureReport(
            brain: selectedBrain.displayName,
            shown: shown,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?",
            system: "\(device.systemName) \(device.systemVersion)",
            logLines: BrainFailureReportFormatter.logLines(entries)
        )
        let body = BrainFailureReportFormatter.redactedBody(
            report,
            homeDirectory: NSHomeDirectory(),
            userName: nil,
            scrubExtra: { CanaryGuard.fromLocalConfig().scan($0).text }
        )
        return SnagDraft(
            intro: String(localized: """
            This is the whole message: that \(report.brain) couldn't get ready, what M1K3 showed you, the app \
            and system versions, and M1K3's download log from this session. Nothing you typed or said goes with \
            it. It goes to \(RoundTowerReports.recipient) from your own mail app, which opens with it filled in. \
            M1K3 sends nothing itself. Round Tower reads it to find what went wrong, and deletes it if you ask.
            """),
            subject: BrainFailureReportFormatter.subject(report),
            body: body
        )
    }

    /// This process's last hour of `.notice`-and-up lines in the report's categories, oldest first.
    /// The store's position is a hint only, so the date is checked again (MetricLogReader's rule).
    private nonisolated static func recentLogEntries(now: Date = Date()) -> [BrainFailureLogEntry] {
        let since = now.addingTimeInterval(-3600)
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(at: store.position(date: since))
        else { return [] }
        return entries.compactMap { $0 as? OSLogEntryLog }
            .filter {
                $0.subsystem == "app.m1k3" && $0.date >= since
                    && BrainFailureReportFormatter.logCategories.contains($0.category)
            }
            .map {
                BrainFailureLogEntry(
                    date: $0.date, category: $0.category, message: $0.composedMessage,
                    isImportant: $0.level == .error || $0.level == .fault
                )
            }
    }
}
