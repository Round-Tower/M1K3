//
//  BrainFailureReport.swift
//  M1K3Diagnostics
//
//  The report a phone offers when a brain won't get ready (Kev, 2026-10-30: "no option on iOS to
//  send logs"). Same path as the snag report: shown and editable first, sent by the user's own
//  mail app (`MailtoURL`, `MailHandoff`). The stored properties are the whole of what leaves,
//  pinned by reflection in BrainFailureReportTests: the brain, the line M1K3 showed, the app and
//  system versions, and an excerpt of M1K3's own log.
//
//  The excerpt is the risky part, so it has one gate, `logLines`. Only `logCategories` pass: the
//  download log and the iOS brain-load log say what the network and the disk did. Other
//  categories can hold the user's words (`memory-distill` logs remembered facts in the clear), so
//  this is an allow-list, and a new category stays out until someone reads what it logs.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-30, Confidence 0.8 (pure, TDD-pinned; the sheet and the
//  OSLogStore read are verify-by-launch). Prior: none (new file; SnagReport's shape).
//

import Foundation

/// One log entry as the shell read it, for `logLines` to judge.
public struct BrainFailureLogEntry: Sendable, Equatable {
    public let date: Date
    public let category: String
    public let message: String
    /// An error or fault: kept even when progress lines flood the excerpt.
    public let isImportant: Bool

    public init(date: Date, category: String, message: String, isImportant: Bool) {
        self.date = date
        self.category = category
        self.message = message
        self.isImportant = isImportant
    }
}

public struct BrainFailureReport: Sendable, Equatable {
    /// The brain's display name ("Lil", "Big").
    public var brain: String
    /// The line M1K3 showed the user.
    public var shown: String
    public var appVersion: String
    public var build: String
    /// "iOS 27.2": `RoundTowerReports.subject(system:version:)` takes the platform from it.
    public var system: String
    /// `BrainFailureReportFormatter.logLines`' output. Often the real cause is only here.
    public var logLines: [String]

    public init(brain: String, shown: String, appVersion: String, build: String, system: String, logLines: [String]) {
        self.brain = brain
        self.shown = shown
        self.appVersion = appVersion
        self.build = build
        self.system = system
        self.logLines = logLines
    }
}

public enum BrainFailureReportFormatter {
    /// The log categories a report may carry (see the header: an allow-list on purpose).
    public static let logCategories: Set<String> = ["model-download", "ios-core"]
    public static let maxLogLines = 40

    // `nonisolated(unsafe)`: configured once here, read-only after (MetricPayloadSummary's idiom).
    private nonisolated(unsafe) static let timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// The excerpt, oldest first: allowed categories only, every error kept, then the newest lines.
    public static func logLines(_ entries: [BrainFailureLogEntry]) -> [String] {
        DiagnosticLogPartition.select(
            entries.filter { logCategories.contains($0.category) },
            maxLines: maxLogLines,
            isImportant: \.isImportant
        )
        .map { "\(timestamp.string(from: $0.date)) [\($0.category)] \($0.message)" }
    }

    /// The email body. Plain text: mail clients render mailto bodies verbatim.
    public static func body(_ report: BrainFailureReport) -> String {
        var lines = [
            "This email says \(report.brain) couldn't get ready on this device. It holds the brain, what M1K3 "
                + "showed you, the app and system versions, M1K3's download log from this session, and anything "
                + "you add below.",
            "It does not hold anything you typed or said, or your memories and documents.",
            "",
            "What happened: \(report.brain) couldn't get ready.",
            "M1K3 showed: \(report.shown)",
            "App: \(report.appVersion) (\(report.build)) · \(report.system)",
        ]
        if !report.logLines.isEmpty {
            lines += ["", "M1K3's log from this session:"] + report.logLines
        }
        lines += ["", "What were you doing when it happened?", ""]
        return lines.joined(separator: "\n")
    }

    /// The body as the sheet shows it. `DiagnosticRedactor` runs over the log lines only; M1K3's
    /// own lines are never redacted, so a user called "Lil" cannot mangle them. Then `scrubExtra`
    /// runs over the whole redacted body (the app passes CanaryGuard), SnagReportFormatter's order.
    public static func redactedBody(
        _ report: BrainFailureReport,
        homeDirectory: String,
        userName: String?,
        scrubExtra: (String) -> String = { $0 }
    ) -> String {
        let redactor = DiagnosticRedactor(homeDirectory: homeDirectory, userName: userName)
        var scrubbed = report
        scrubbed.logLines = report.logLines.map(redactor.redact)
        return scrubExtra(body(scrubbed))
    }

    public static func subject(_ report: BrainFailureReport) -> String {
        RoundTowerReports.subject(system: report.system, version: report.appVersion)
    }
}
