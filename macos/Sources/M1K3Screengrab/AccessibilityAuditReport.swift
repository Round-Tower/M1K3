//
//  AccessibilityAuditReport.swift
//  M1K3Screengrab
//
//  The accessibility audit's findings as plain values and one readable report.
//  The UI test suites (`UITests/Screengrab*/AccessibilityAuditUITests.swift`)
//  run Xcode's `performAccessibilityAudit` on each screen and hand every issue
//  here as strings, so the counting, de-duplication and wording are pinned by
//  `swift test` and are the same on the Mac and the phone.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-13, Confidence 0.85 (pinned by
//  AccessibilityAuditReportTests; what Xcode's audit reports is not ours), Prior: Unknown
//

/// One issue Xcode's accessibility audit raised on one screen.
public struct AccessibilityAuditFinding: Sendable, Hashable {
    /// The screen it was found on (the plate's name).
    public var screen: String
    /// What kind of issue: "contrast", "description", "text clipped"…
    public var kind: String
    /// The element's own name, or empty when it has none.
    public var element: String
    /// Xcode's description of the issue.
    public var detail: String

    public init(screen: String, kind: String, element: String, detail: String) {
        self.screen = screen
        self.kind = kind
        self.element = element
        self.detail = detail
    }
}

public enum AccessibilityAuditReport {
    /// Findings with exact repeats removed, first-seen order kept. The audit
    /// can raise the same issue on the same element more than once in a pass.
    public static func unique(_ findings: [AccessibilityAuditFinding]) -> [AccessibilityAuditFinding] {
        var seen = Set<AccessibilityAuditFinding>()
        return findings.filter { seen.insert($0).inserted }
    }

    /// One line: how many issues, on how many screens, and the count per kind.
    public static func summary(_ findings: [AccessibilityAuditFinding]) -> String {
        let findings = unique(findings)
        guard !findings.isEmpty else { return "0 issues" }
        let screens = Set(findings.map(\.screen)).count
        var counts: [String: Int] = [:]
        for finding in findings {
            counts[finding.kind, default: 0] += 1
        }
        let ranked = counts.keys.sorted { lhs, rhs in
            let left = counts[lhs] ?? 0, right = counts[rhs] ?? 0
            return left == right ? lhs < rhs : left > right
        }
        let kinds = ranked.map { kind in "\(kind) \(counts[kind] ?? 0)" }.joined(separator: ", ")
        let issues = findings.count == 1 ? "1 issue" : "\(findings.count) issues"
        let on = screens == 1 ? "1 screen" : "\(screens) screens"
        return "\(issues) on \(on): \(kinds)"
    }

    /// The whole report: the summary, then each screen's findings, one per line.
    public static func render(_ findings: [AccessibilityAuditFinding]) -> String {
        let findings = unique(findings)
        var lines = [summary(findings)]
        var order: [String] = []
        for finding in findings where !order.contains(finding.screen) {
            order.append(finding.screen)
        }
        for screen in order {
            let here = findings.filter { $0.screen == screen }
            lines.append("")
            lines.append("## \(screen) (\(here.count))")
            for finding in here {
                let name = finding.element.trimmingCharacters(in: .whitespacesAndNewlines)
                let detail = finding.detail
                    .split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .joined(separator: " ")
                lines.append("- [\(finding.kind)] \(name.isEmpty ? "(unnamed element)" : name): \(detail)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
