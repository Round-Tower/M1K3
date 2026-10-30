//
//  SnagReport.swift
//  M1K3Diagnostics
//
//  The "I hit a snag last time" report (#750). When the last session didn't close cleanly
//  (`SessionGuard`), M1K3 offers once to email Round Tower a short report, through #708's path:
//  shown and editable first, sent by the user's own mail app (`MailtoURL`, `MailHandoff`). The
//  stored properties are the whole of what leaves, pinned by reflection in SnagReportTests: when
//  the session began, when the next launch noticed, the brain, the app and system versions, and
//  any MetricKit crash summaries the device kept (`MetricPayloadSummary.line`, never raw payload
//  JSON). The body ends on "What were you doing when it happened?", the one line that can lead
//  to a fix; the user types it or not.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-29, Confidence 0.8 (pure, TDD-pinned; the sheet and
//  the mail hand-off are verify-by-launch). Prior: none (new file; FieldReport's shape).
//  Review: Kev + claude-opus-5.5, 2026-10-29 — `RoundTowerReports` and `SnagNote` live here so the Mac and phone
//  shells share them. Confidence 0.8.
//  Review: Kev + claude-opus-5.5, 2026-10-29 (pre-push review fold) — "Brain now:", since the brain is the one the
//  next launch restored; the Mac reporter reads its recipient from `RoundTowerReports` too. Confidence 0.8.
//  Review: Kev + claude-opus-5.5, 2026-10-30 — the subject takes Round Tower's support format (Kev: "Lexy | iOS Support
//  | v4.0.2"), shared with the field report through `RoundTowerReports.subject`. Confidence 0.8.
//

import Foundation

/// Where opt-in reports go, on every shell: the contact address in SECURITY.md (Kev's ruling, #708).
public enum RoundTowerReports {
    public static let recipient = "hello@round-tower.ie"

    /// Round Tower's support subject, the format its other apps use ("Lexy | iOS Support | v4.0.2"):
    /// the app, the platform and the version, so nothing the user wrote. The rest is in the body.
    public static func subject(platform: String, version: String) -> String {
        "M1K3 | \(platform) Support | v\(version)"
    }
}

/// A session that didn't close cleanly, waiting on the chat surface's one-time offer.
public struct SnagNote: Sendable, Equatable {
    /// When that session began.
    public let openedAt: Date
    /// When this launch noticed.
    public let noticedAt: Date

    public init(openedAt: Date, noticedAt: Date) {
        self.openedAt = openedAt
        self.noticedAt = noticedAt
    }
}

public struct SnagReport: Sendable, Equatable {
    /// When the session that didn't close began.
    public var openedAt: Date
    /// When the next launch noticed.
    public var noticedAt: Date
    /// The brain's display name ("Lil", "Big", "Mini") at the next launch: the restored choice.
    public var brain: String
    public var appVersion: String
    public var build: String
    /// "macOS 27.0", "iOS 27.0": one build ships to both, so the version alone can't say which.
    public var system: String
    /// MetricKit digest lines for crashes this device kept, newest first. Often empty.
    public var crashLines: [String]

    public init(
        openedAt: Date, noticedAt: Date, brain: String, appVersion: String, build: String, system: String,
        crashLines: [String]
    ) {
        self.openedAt = openedAt
        self.noticedAt = noticedAt
        self.brain = brain
        self.appVersion = appVersion
        self.build = build
        self.system = system
        self.crashLines = crashLines
    }
}

public enum SnagReportFormatter {
    // `nonisolated(unsafe)`: configured once here, read-only after (MetricPayloadSummary's idiom).
    private nonisolated(unsafe) static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// The email body. Plain text: mail clients render mailto bodies verbatim.
    public static func body(_ report: SnagReport) -> String {
        var lines = [
            "This email says M1K3 didn't close cleanly last time. It holds when that session began, the brain, "
                + "the app and system versions, any crash summaries this device kept, and anything you add below.",
            "It does not hold anything you typed or said, or your memories and documents.",
            "",
            "What happened: M1K3 didn't close cleanly. That session began \(timestamp.string(from: report.openedAt)); "
                + "the next launch noticed at \(timestamp.string(from: report.noticedAt)).",
            // The brain the next launch restored: the one that crashed is not recorded.
            "Brain now: \(report.brain) · App: \(report.appVersion) (\(report.build)) · \(report.system)",
        ]
        if !report.crashLines.isEmpty {
            lines += ["", "Crash summaries this device kept:"] + report.crashLines
        }
        lines += ["", "What were you doing when it happened?", ""]
        return lines.joined(separator: "\n")
    }

    /// The body as the sheet shows it. `DiagnosticRedactor` runs over the crash lines only (a
    /// binary name could carry a path); M1K3's own lines are never redacted, so a user called
    /// "Big" cannot mangle them. Then `scrubExtra` runs over the whole redacted body (the app
    /// passes CanaryGuard), FieldReportFormatter's order.
    public static func redactedBody(
        _ report: SnagReport,
        homeDirectory: String,
        userName: String?,
        scrubExtra: (String) -> String = { $0 }
    ) -> String {
        let redactor = DiagnosticRedactor(homeDirectory: homeDirectory, userName: userName)
        var scrubbed = report
        scrubbed.crashLines = report.crashLines.map(redactor.redact)
        return scrubExtra(body(scrubbed))
    }

    /// Round Tower's support subject. The platform is `system` less its version number.
    public static func subject(_ report: SnagReport) -> String {
        let platform = report.system.split(separator: " ").first.map(String.init) ?? report.system
        return RoundTowerReports.subject(platform: platform, version: report.appVersion)
    }
}
