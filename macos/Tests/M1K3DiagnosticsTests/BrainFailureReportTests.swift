//
//  BrainFailureReportTests.swift
//  M1K3DiagnosticsTests
//
//  The report a phone offers when a brain won't get ready (Kev, 2026-10-30: "no option on iOS to
//  send logs"). The brain, the line M1K3 showed, the app and system versions, and M1K3's own
//  download log, and nothing else. The stored properties are the contract, pinned by reflection.
//  The log excerpt is the risky part: the memory log holds the user's own words, so only the
//  download and brain-load categories may pass.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-30, Confidence 0.8 (pure; the sheet and the log read
//  are verify-by-launch). Prior: none (new file).
//

import Foundation
@testable import M1K3Diagnostics
import Testing

private func report(logLines: [String] = []) -> BrainFailureReport {
    BrainFailureReport(
        brain: "Lil",
        shown: "Couldn't reach the download server. Check your connection and try again.",
        appVersion: "1.3.0",
        build: "542",
        system: "iOS 27.2",
        logLines: logLines
    )
}

private func entry(
    _ category: String, _ message: String, important: Bool = false, at seconds: TimeInterval = 1_800_000_000
) -> BrainFailureLogEntry {
    BrainFailureLogEntry(
        date: Date(timeIntervalSince1970: seconds), category: category, message: message, isImportant: important
    )
}

struct BrainFailureReportTests {
    @Test("the payload is exactly: brain, the line shown, app version, build, system, log lines")
    func fieldSet() {
        let labels = Mirror(reflecting: report()).children.compactMap(\.label)
        #expect(labels == ["brain", "shown", "appVersion", "build", "system", "logLines"])
    }

    @Test("only the download and brain-load logs pass: the memory log holds the user's own words")
    func logCategories() {
        let lines = BrainFailureReportFormatter.logLines([
            entry("model-download", "snapshot start"),
            entry("memory-distill", "remembered: the user's private fact"),
            entry("ios-core", "brain warm failed: timed out"),
            entry("chat", "the user's question"),
        ])
        #expect(lines.count == 2)
        #expect(lines.allSatisfy { !$0.contains("private fact") && !$0.contains("question") })
        #expect(lines[0].contains("[model-download] snapshot start"))
        #expect(lines[1].contains("[ios-core] brain warm failed: timed out"))
    }

    @Test("the excerpt is bounded, and a flood of progress lines can't evict the error that matters")
    func logBudget() {
        var entries = [entry("ios-core", "brain warm failed: timed out", important: true)]
        entries += (0 ..< 200).map { entry("model-download", "progress \($0)") }
        let lines = BrainFailureReportFormatter.logLines(entries)
        #expect(lines.count == BrainFailureReportFormatter.maxLogLines)
        #expect(lines.first?.contains("brain warm failed") == true)
        #expect(lines.last?.contains("progress 199") == true)
    }

    @Test("the body says what it holds and leaves out, and ends on the one question that helps")
    func body() {
        let body = BrainFailureReportFormatter.body(report(logLines: ["12:00:00Z [ios-core] line"]))
        #expect(body.contains("It does not hold anything you typed or said, or your memories and documents."))
        #expect(body.contains("Lil couldn't get ready"))
        #expect(body.contains("M1K3 showed: Couldn't reach the download server."))
        #expect(body.contains("App: 1.3.0 (542) · iOS 27.2"))
        #expect(body.contains("12:00:00Z [ios-core] line"))
        #expect(body.hasSuffix("What were you doing when it happened?\n"))
    }

    @Test("with no log, the section is left out")
    func noLog() {
        #expect(!BrainFailureReportFormatter.body(report()).contains("log from this session:"))
    }

    @Test("log lines are redacted; M1K3's own lines are left alone, even for a user called Lil")
    func redaction() {
        let body = BrainFailureReportFormatter.redactedBody(
            report(logLines: ["12:00:00Z [model-download] /Users/lil/Library/models failed"]),
            homeDirectory: "/Users/lil",
            userName: "Lil"
        )
        #expect(body.contains("Lil couldn't get ready"))
        #expect(!body.contains("/Users/lil"))
    }

    @Test("scrubExtra runs over the whole redacted body")
    func scrubExtra() {
        let body = BrainFailureReportFormatter.redactedBody(
            report(), homeDirectory: "/Users/x", userName: nil, scrubExtra: { $0.replacingOccurrences(of: "Lil", with: "•") }
        )
        #expect(!body.contains("Lil"))
    }

    @Test("the subject is Round Tower's support format")
    func subject() {
        #expect(BrainFailureReportFormatter.subject(report()) == "M1K3 | iOS Support | v1.3.0")
    }
}
