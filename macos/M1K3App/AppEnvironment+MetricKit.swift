//
//  AppEnvironment+MetricKit.swift
//  M1K3
//
//  Starts the MetricKit collector (MetricKitCollector.swift) once at launch
//  and exposes its recent digest lines to the "Report an issue" flow's
//  opt-in inclusion (AdvancedSettingsPane → IssueReporter).
//
//  Signed: Kev + claude-fable-5, 2026-07-30, Confidence 0.8 (thin composition
//  glue over the SDK-header-verified MetricKitCollector; app-target file,
//  verify-by-launch). Prior: Unknown.
//

import Foundation

extension AppEnvironment {
    /// Opt-in (default OFF): include recent MetricKit digest lines in a filed
    /// issue report. Off by default like the Agent Interaction Log toggle —
    /// diagnostics only leave the device through the explicit report flow,
    /// and only when the user asks.
    nonisolated static let includeMetricDigestsInIssueKey = "issueReport.includeMetricDigests"

    /// Subscribe MXMetricManager once at launch — cheap + synchronous
    /// (registration only; payloads arrive later via the delegate callbacks,
    /// at most once/day, per Apple's own docs).
    func startMetricKitCollection() {
        MetricKitCollector.shared.start()
    }

    /// The most recent MetricKit digest SUMMARY LINES (never raw payload
    /// text) for the opt-in inclusion in a filed issue report.
    func recentMetricDigestLines(limit: Int = 10) -> [String] {
        MetricKitCollector.shared.recentDigestLines(limit: limit)
    }
}
