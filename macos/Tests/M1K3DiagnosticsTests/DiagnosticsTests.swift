//
//  DiagnosticsTests.swift
//  M1K3DiagnosticsTests
//
//  The privacy scrub + report formatting contract. The redactor tests are the
//  load-bearing ones: a miss here leaks PII into a (potentially public) issue.
//

import Foundation
@testable import M1K3Diagnostics
import Testing

struct DiagnosticRedactorTests {
    private let redactor = DiagnosticRedactor(
        homeDirectory: "/Users/kevinmurphy",
        userName: "Kevin Murphy"
    )

    @Test("the current user's home dir collapses to ~")
    func homeDir() {
        let input = "loaded /Users/kevinmurphy/Library/Containers/app.m1k3/Data/store.db"
        #expect(redactor.redact(input) == "loaded ~/Library/Containers/app.m1k3/Data/store.db")
    }

    @Test("other accounts' /Users paths are masked to /Users/[user]")
    func otherUsers() {
        let input = "fallback at /Users/someoneelse/Desktop/file.txt"
        #expect(redactor.redact(input) == "fallback at /Users/[user]/Desktop/file.txt")
    }

    @Test("email addresses are removed")
    func emails() {
        let input = "signed in as kevin@round-tower.ie just now"
        #expect(redactor.redact(input) == "signed in as [email] just now")
    }

    @Test("the user's profile name is removed, case-insensitively and whole-word")
    func profileName() {
        let input = "Note from Kevin Murphy: kevin murphy said hi to Kevinson"
        let out = redactor.redact(input)
        #expect(out.contains("[name]"))
        #expect(!out.lowercased().contains("kevin murphy"))
        // Whole-word only — must not maul "Kevinson".
        #expect(out.contains("Kevinson"))
    }

    @Test("a combined line is fully scrubbed")
    func combined() {
        let input = "Kevin Murphy (kevin@round-tower.ie) at /Users/kevinmurphy/notes.md"
        let out = redactor.redact(input)
        #expect(!out.contains("kevin@round-tower.ie"))
        #expect(!out.contains("/Users/kevinmurphy"))
        #expect(!out.lowercased().contains("kevin murphy"))
    }

    @Test("a name with regex metacharacters does not break the scrub")
    func nameWithMetacharacters() {
        let r = DiagnosticRedactor(homeDirectory: "", userName: "A.(x)")
        #expect(r.redact("hello A.(x) there") == "hello [name] there")
    }

    @Test("empty user name is a no-op for name redaction")
    func emptyName() {
        let r = DiagnosticRedactor(homeDirectory: "/Users/kevinmurphy", userName: "")
        #expect(r.redact("plain text") == "plain text")
    }
}

struct IssueReportFormatterTests {
    private func sample(whatHappened: String = "It crashed", logs: String = "line1\nline2") -> IssueReport {
        IssueReport(
            title: "Crash on launch",
            whatHappened: whatHappened,
            appVersion: "1.2.0",
            build: "42",
            osVersion: "macOS 26.0",
            device: "Mac15,3",
            memoryGB: 32,
            activeBrain: "Lil", // BrainTier.lil.displayName since the #109 rename — keep the fixture honest
            logs: logs
        )
    }

    @Test("the body carries environment and fenced logs")
    func body() {
        let md = IssueReportFormatter.markdownBody(sample())
        #expect(md.contains("### What happened\nIt crashed"))
        #expect(md.contains("- App: 1.2.0 (42)"))
        #expect(md.contains("- macOS: macOS 26.0"))
        #expect(md.contains("- Active brain: Lil"))
        #expect(md.contains("```\nline1\nline2\n```"))
    }

    @Test("an empty what-happened section is omitted")
    func omitsEmptyWhatHappened() {
        let md = IssueReportFormatter.markdownBody(sample(whatHappened: "   "))
        #expect(!md.contains("### What happened"))
        #expect(md.contains("### Environment"))
    }

    @Test("empty logs render a placeholder, never an empty fence")
    func emptyLogsPlaceholder() {
        let md = IssueReportFormatter.markdownBody(sample(logs: ""))
        #expect(md.contains("(none captured)"))
    }

    @Test("metric digest lines are omitted by default (opt-in, empty means silent)")
    func metricDigestsOmittedByDefault() {
        let md = IssueReportFormatter.markdownBody(sample())
        #expect(!md.contains("MetricKit"))
    }

    @Test("opted-in metric digest lines render their own section, verbatim")
    func metricDigestsSection() {
        var report = sample()
        report.metricDigests = ["crash · 2026-07-29T00:00:00Z · v1.4.0 (88) · M1K3"]
        let md = IssueReportFormatter.markdownBody(report)
        #expect(md.contains("### Recent diagnostics (MetricKit)"))
        #expect(md.contains("crash · 2026-07-29T00:00:00Z · v1.4.0 (88) · M1K3"))
    }
}

struct GitHubIssueURLTests {
    @Test("a short body builds a prefilled, encoded new-issue URL")
    func shortBody() throws {
        let built = try #require(GitHubIssueURL.newIssue(
            repo: "Round-Tower/m1k3",
            title: "Bug: thing",
            body: "a body with spaces & symbols"
        ))
        #expect(!built.truncated)
        let s = built.url.absoluteString
        #expect(s.hasPrefix("https://github.com/Round-Tower/m1k3/issues/new?"))
        #expect(s.contains("title="))
        #expect(s.contains("body="))
        // Querystring is percent-encoded — no raw spaces leak through.
        #expect(!s.contains("with spaces"))
    }

    @Test("an over-long body is truncated and flagged")
    func longBody() throws {
        let huge = String(repeating: "x", count: 10000)
        let built = try #require(GitHubIssueURL.newIssue(
            repo: "Round-Tower/m1k3",
            title: "Big",
            body: huge,
            maxBodyChars: 100
        ))
        #expect(built.truncated)
        #expect(built.url.absoluteString.contains("clipboard"))
    }
}
