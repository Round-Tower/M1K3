//
//  SnagReportTests.swift
//  M1K3DiagnosticsTests
//
//  The "I hit a snag last time" report (#750): when the session that didn't close began, when
//  it was noticed, the brain, the app and system versions, any crash summaries the device
//  kept, and nothing else. Like FieldReport, the stored properties ARE the contract, pinned
//  by reflection, and the body says what it leaves out. The user sees and edits it first, and
//  their own mail app sends it.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-29, Confidence 0.8 (pure; the sheet and the mail
//  hand-off are verify-by-launch). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-29 — the recipient pin. Confidence 0.8.
//  Review: Kev + claude-opus-5.5, 2026-10-29 (pre-push review fold) — "Brain now:" (it is the brain the next
//  launch restored, not necessarily the one that crashed). Confidence 0.8.
//  Review: claude-opus-5-5, 2026-11-21 — `mlxErrors` (MLX's own messages from `MLXFailureLedger`): a section of
//  their own, redacted like the crash lines. Confidence 0.85.
//

import Foundation
@testable import M1K3Diagnostics
import Testing

private func report(crashLines: [String] = [], mlxErrors: [String] = []) -> SnagReport {
    SnagReport(
        openedAt: Date(timeIntervalSince1970: 1_800_000_000),
        noticedAt: Date(timeIntervalSince1970: 1_800_003_600),
        brain: "Big",
        appVersion: "1.3.0",
        build: "542",
        system: "macOS 27.0",
        crashLines: crashLines,
        mlxErrors: mlxErrors
    )
}

struct SnagReportTests {
    @Test("the payload is exactly: the two times, brain, app version, build, system, crash summaries, brain errors")
    func fieldSet() {
        let labels = Mirror(reflecting: report()).children.compactMap(\.label)
        #expect(labels == ["openedAt", "noticedAt", "brain", "appVersion", "build", "system", "crashLines", "mlxErrors"])
    }

    @Test("MLX's own messages ride along when the device kept some; none, no section (2026-11-21)")
    func brainErrorsAreOptional() {
        #expect(!SnagReportFormatter.body(report()).contains("Brain errors"))
        let line = "2027-01-15T08:59:00Z [metal::malloc] Unable to allocate 268435456 bytes."
        let body = SnagReportFormatter.body(report(mlxErrors: [line]))
        #expect(body.contains("Brain errors this device kept:\n" + line))
        #expect(body.contains("brain errors"), "the preamble says they are in it")
    }

    @Test("brain errors are redacted like crash lines: MLX can name a file path")
    func brainErrorsAreRedacted() {
        let leaky = report(mlxErrors: ["2027-01-15T08:59:00Z [load] Failed to open /Users/aoife/models/x.safetensors"])
        let body = SnagReportFormatter.redactedBody(leaky, homeDirectory: "/Users/aoife", userName: nil)
        #expect(!body.contains("/Users/aoife"))
        #expect(body.contains("[load] Failed to open"))
    }

    @Test("the body says what happened, when, on what, and what it leaves out")
    func bodyCarriesTheFacts() {
        let body = SnagReportFormatter.body(report())
        #expect(body.contains("didn't close cleanly"))
        #expect(body.contains("2027-01-15T08:00:00Z"), "when the session began, in UTC")
        #expect(body.contains("2027-01-15T09:00:00Z"), "when the next launch noticed")
        // The brain the next launch restored, not necessarily the one that crashed.
        #expect(body.contains("Brain now: Big · App: 1.3.0 (542) · macOS 27.0"))
        for absent in ["anything you typed or said", "memories", "documents"] {
            #expect(body.contains(absent), "the preamble names \(absent) as left out")
        }
        #expect(body.hasSuffix("What were you doing when it happened?\n"), "the user's line is last, ready to type on")
    }

    @Test("crash summaries ride along when the device kept some; none, no section")
    func crashLinesAreOptional() {
        #expect(!SnagReportFormatter.body(report()).contains("Crash summaries"))
        let body = SnagReportFormatter.body(report(crashLines: ["crash · 2027-01-15T08:59:00Z · v1.3.0 · M1K3"]))
        #expect(body.contains("Crash summaries this device kept:\ncrash · 2027-01-15T08:59:00Z · v1.3.0 · M1K3"))
    }

    @Test("reports go to the one address SECURITY.md names, on every shell")
    func recipient() {
        #expect(RoundTowerReports.recipient == "hello@round-tower.ie")
    }

    @Test("the subject is Round Tower's support format: the app, the platform and the version, nothing else")
    func subject() {
        #expect(SnagReportFormatter.subject(report()) == "M1K3 | macOS Support | v1.3.0")
        for (system, platform) in [("iOS 27.0", "iOS"), ("iPadOS 27.0", "iPadOS"), ("visionOS 27.0", "visionOS")] {
            var other = report()
            other.system = system
            #expect(SnagReportFormatter.subject(other) == "M1K3 | \(platform) Support | v1.3.0")
        }
    }

    @Test("crash lines are redacted; M1K3's own lines are left alone, even for a user called Big")
    func redaction() {
        let leaky = report(crashLines: ["crash · v1.3.0 · /Users/aoife/Library/x.dylib", "hang · kev@example.com"])
        let body = SnagReportFormatter.redactedBody(leaky, homeDirectory: "/Users/kev", userName: "Big")
        #expect(!body.contains("/Users/aoife"))
        #expect(!body.contains("kev@example.com"))
        #expect(body.contains("Brain now: Big · App: 1.3.0 (542)"), "the user's name never mangles M1K3's lines")
    }

    @Test("the extra scrub runs last, over the redacted body")
    func extraScrubRunsLast() {
        var seen = ""
        let body = SnagReportFormatter.redactedBody(
            report(crashLines: ["crash · /Users/kev/x"]), homeDirectory: "/Users/kev", userName: nil,
            scrubExtra: { text in
                seen = text
                return text + "[scrubbed]"
            }
        )
        #expect(!seen.contains("/Users/kev/x"), "the scrub sees the redacted text")
        #expect(body.hasSuffix("[scrubbed]"))
    }
}
