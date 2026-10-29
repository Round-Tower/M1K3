//
//  FieldReporter.swift
//  M1K3App
//
//  The "Send this exchange to Round Tower…" glue (#708), patterned on IssueReporter: build the
//  redacted body from ONE exchange (DiagnosticRedactor for paths / emails / the profile name,
//  then CanaryGuard for planted honeypots), and when — only when — the sheet's Send button is
//  pressed, open a mailto: link in the user's own mail app. No token, no network call from the
//  app itself; the user's Sent folder is the record. An over-long or unopenable link puts the
//  full body on the clipboard instead and says so.
//
//  The payload, the scrub (`FieldReportFormatter.redactedBody`), the link builder and the send
//  decision (`MailHandoff`) are the pure, unit-pinned M1K3Diagnostics core; the pairing is
//  ChatSession.exchange(for:). This file only supplies their OS inputs (Bundle, the home path,
//  the display name, the canary config) and the three OS calls (workspace, pasteboard), and is
//  verified by launch. FieldReportScanTests pins that nothing but FieldReportSheet calls `send`.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-26, Confidence 0.75 (core TDD-pinned; the mail-app
//  hand-off and the real mailto length ceiling are verify-at-⌘R, UNVERIFIED this run).
//  Prior: none (new file).
//  Review: Kev + claude-fable-5.1, 2026-10-26 (pre-push review fold) — the redactor gets the user's display name
//  (`AppEnvironment.userDisplayNameKey`), not the About-you profile text IssueReporter passes, which never matched
//  a bare first name; a missing mail handler is told apart from a link that would not open. Confidence 0.75.
//  Review: Kev + claude-opus-5.5, 2026-10-26 (code-review fold) — the scrub order and the send outcomes left
//  this TDD_SKIP glue for tested seams (`redactedBody`, `MailHandoff`); a link that could not be built is now
//  a could-not-open, not "no mail app". What stays here is inputs and OS calls. Confidence 0.8.
//  Review: Kev + claude-opus-5.5, 2026-10-27 (bot review fold) — comment only: `redactedBody` now redacts the
//  user's fields and leaves M1K3's own lines alone. Confidence 0.8.
//  Review: Kev + claude-opus-5.5, 2026-10-29 — #750: FieldReportDraft gains `kind`; snagDraft builds the redacted
//  SnagReport for the same sheet and send. Confidence 0.8.
//

import AppKit
import Foundation
import M1K3Chat
import M1K3Diagnostics

/// One report waiting on the sheet (`.sheet(item:)` needs an identity; the body is a value).
struct FieldReportDraft: Identifiable {
    /// What the sheet is sending: one exchange from a thumbs-down (#708), or the note that the
    /// last session didn't close cleanly (#750). Only the sheet's title and sentence differ.
    enum Kind {
        case exchange
        case snag
    }

    let id = UUID()
    var kind: Kind = .exchange
    /// Brain + version only — never the user's words.
    let subject: String
    /// The exact, already-redacted text the user sees, edits and sends.
    let body: String
}

enum FieldReporter {
    /// Where a report goes: the contact address in SECURITY.md. The address is Kev's ruling
    /// (#708 stays open for it).
    static let recipient = RoundTowerReports.recipient

    /// The redacted draft for one exchange. The brain is the answer's stamp, or the resident
    /// brain for a pre-trace turn. The scrub is `FieldReportFormatter.redactedBody`, unit-pinned
    /// in M1K3Diagnostics: every field the user or the model wrote, the user's own question
    /// included (M1K3's own lines are left alone), then the canary pass over the redacted body.
    /// This supplies its inputs: this Mac's home path, the display name from onboarding (what
    /// M1K3 greets the user by, the key `saveFirstRunName` writes), and the local honeypot list.
    static func draft(exchange: AnswerExchange, note: String?, fallbackBrain: String) -> FieldReportDraft {
        let report = FieldReport(
            question: exchange.question,
            answer: exchange.answer,
            brain: exchange.brain ?? fallbackBrain,
            appVersion: infoString("CFBundleShortVersionString"),
            build: infoString("CFBundleVersion"),
            note: note
        )
        let body = FieldReportFormatter.redactedBody(
            report,
            homeDirectory: NSHomeDirectory(),
            userName: UserDefaults.standard.string(forKey: AppEnvironment.userDisplayNameKey),
            scrubExtra: { CanaryGuard.fromLocalConfig().scan($0).text }
        )
        return FieldReportDraft(subject: FieldReportFormatter.subject(report), body: body)
    }

    /// The redacted draft for #750's snag report: when the session that didn't close began, the
    /// brain now restored, the app and macOS versions, and any MetricKit crash summaries. The
    /// scrub is `SnagReportFormatter.redactedBody`, unit-pinned in M1K3Diagnostics, with the same
    /// home path, display name and canary pass as an exchange.
    static func snagDraft(_ note: SnagNote, brain: String, crashLines: [String]) -> FieldReportDraft {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let report = SnagReport(
            openedAt: note.openedAt,
            noticedAt: note.noticedAt,
            brain: brain,
            appVersion: infoString("CFBundleShortVersionString"),
            build: infoString("CFBundleVersion"),
            system: "macOS \(os.majorVersion).\(os.minorVersion)",
            crashLines: crashLines
        )
        let body = SnagReportFormatter.redactedBody(
            report,
            homeDirectory: NSHomeDirectory(),
            userName: UserDefaults.standard.string(forKey: AppEnvironment.userDisplayNameKey),
            scrubExtra: { CanaryGuard.fromLocalConfig().scan($0).text }
        )
        return FieldReportDraft(kind: .snag, subject: SnagReportFormatter.subject(report), body: body)
    }

    /// Open the user's mail app with the message filled in. Called from the sheet's Send
    /// button and nowhere else. `MailHandoff` decides the outcome and when the full body
    /// rides the clipboard; this hands it the link and the OS.
    @MainActor
    static func send(subject: String, body: String) -> MailHandoff.Outcome {
        MailHandoff.send(
            link: MailtoURL.compose(to: recipient, subject: subject, body: body), body: body, via: WorkspaceMail()
        )
    }

    /// The whole body to the clipboard — the sheet's "Copy instead", and the fallback above.
    @MainActor
    static func copy(_ body: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)
    }

    private static func infoString(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "?"
    }
}

/// The three OS calls `MailHandoff` needs, and nothing else.
@MainActor
private struct WorkspaceMail: MailOpening {
    func hasHandler(for url: URL) -> Bool {
        NSWorkspace.shared.urlForApplication(toOpen: url) != nil
    }

    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }

    func copy(_ text: String) {
        FieldReporter.copy(text)
    }
}
