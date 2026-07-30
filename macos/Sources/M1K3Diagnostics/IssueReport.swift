//
//  IssueReport.swift
//  M1K3Diagnostics
//
//  The diagnostic bundle for a GitHub issue, plus pure formatters for the
//  markdown body and the prefilled new-issue URL. No network, no token: the app
//  copies the full body to the clipboard and opens the prefilled GitHub page for
//  the user to review and submit (secret-free filing).
//
//  Signed: Kev + claude-opus-4-8, 2026-06-28, Confidence 0.85 (pure formatting,
//  TDD-pinned incl. the URL length cap). Prior: Unknown.
//

import Foundation

/// A diagnostic bundle. This type does no scrubbing, and since the 109-12
/// extraction `logs` may legitimately be RAW at construction: the sanctioned
/// pipeline is `DiagnosticsReportBuilder.build`, which redacts a copy before
/// formatting. ⚠️ Never hand a raw-logs report straight to
/// `IssueReportFormatter.markdownBody` — that skips the PII scrub.
public struct IssueReport: Sendable, Equatable {
    public var title: String
    public var whatHappened: String
    public var appVersion: String
    public var build: String
    public var osVersion: String
    public var device: String
    public var memoryGB: Int
    public var activeBrain: String
    public var logs: String
    /// Human-readable MetricKit digest SUMMARY LINES (kind/date/version/top-
    /// frame — see `MetricPayloadDigest`), never raw payload JSON. Empty
    /// unless the user opts in from Settings; display-safe by construction
    /// like `activeBrain`/`device`, so no redaction pass runs over these.
    public var metricDigests: [String]

    public init(
        title: String,
        whatHappened: String = "",
        appVersion: String,
        build: String,
        osVersion: String,
        device: String,
        memoryGB: Int,
        activeBrain: String,
        logs: String,
        metricDigests: [String] = []
    ) {
        self.title = title
        self.whatHappened = whatHappened
        self.appVersion = appVersion
        self.build = build
        self.osVersion = osVersion
        self.device = device
        self.memoryGB = memoryGB
        self.activeBrain = activeBrain
        self.logs = logs
        self.metricDigests = metricDigests
    }
}

public enum IssueReportFormatter {
    /// The markdown issue body. `whatHappened` leads when present; environment is
    /// always included; logs go in a fenced block so GitHub renders them verbatim.
    public static func markdownBody(_ report: IssueReport) -> String {
        var sections: [String] = []

        let what = report.whatHappened.trimmingCharacters(in: .whitespacesAndNewlines)
        if !what.isEmpty {
            sections.append("### What happened\n\(what)")
        }

        sections.append("""
        ### Environment
        - App: \(report.appVersion) (\(report.build))
        - macOS: \(report.osVersion)
        - Device: \(report.device)
        - Memory: \(report.memoryGB) GB
        - Active brain: \(report.activeBrain)
        """)

        let logs = report.logs.trimmingCharacters(in: .whitespacesAndNewlines)
        sections.append("### Recent logs (redacted)\n```\n\(logs.isEmpty ? "(none captured)" : logs)\n```")

        // Opt-in only: omitted entirely (not even an empty header) when the
        // user didn't include on-device MetricKit summaries for this report.
        if !report.metricDigests.isEmpty {
            sections.append("### Recent diagnostics (MetricKit)\n" + report.metricDigests.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n")
    }
}

public enum GitHubIssueURL {
    public struct Built: Sendable, Equatable {
        public let url: URL
        /// True when the body exceeded the URL cap and was trimmed — the caller
        /// should put the full body on the clipboard and tell the user to paste it.
        public let truncated: Bool
    }

    /// Build a prefilled `…/issues/new` URL. GitHub (and browsers) cap URL length,
    /// so an over-long body is trimmed in the URL and flagged truncated; the full
    /// text is meant to ride the clipboard instead.
    public static func newIssue(
        repo: String,
        title: String,
        body: String,
        maxBodyChars: Int = 6000
    ) -> Built? {
        var body = body
        var truncated = false
        if body.count > maxBodyChars {
            body = String(body.prefix(maxBodyChars))
                + "\n\n_… truncated — the full report is on your clipboard. Paste it here._"
            truncated = true
        }

        var components = URLComponents(string: "https://github.com/\(repo)/issues/new")
        components?.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: body),
        ]
        guard let url = components?.url else { return nil }
        return Built(url: url, truncated: truncated)
    }
}
