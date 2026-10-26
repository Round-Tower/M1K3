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
//  The payload, the body and the link builder are the pure, unit-pinned M1K3Diagnostics core
//  (FieldReport.swift); the pairing is ChatSession.exchange(for:). This file is the OS-facing
//  glue (Bundle, pasteboard, workspace) and is verified by launch. FieldReportScanTests pins
//  that nothing but FieldReportSheet calls `send`.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-26, Confidence 0.75 (core TDD-pinned; the mail-app
//  hand-off and the real mailto length ceiling are verify-at-⌘R, UNVERIFIED this run).
//  Prior: none (new file).
//  Review: Kev + claude-fable-5.1, 2026-10-26 (pre-push review fold) — the redactor gets the user's display name
//  (`AppEnvironment.userDisplayNameKey`), not the About-you profile text IssueReporter passes, which never matched
//  a bare first name; a missing mail handler is told apart from a link that would not open. Confidence 0.75.
//

import AppKit
import Foundation
import M1K3Chat
import M1K3Diagnostics

/// One exchange waiting on the sheet (`.sheet(item:)` needs an identity; the body is a value).
struct FieldReportDraft: Identifiable {
    let id = UUID()
    /// Brain + version only — never the user's words.
    let subject: String
    /// The exact, already-redacted text the user sees, edits and sends.
    let body: String
}

enum FieldReporter {
    /// Where a report goes: the contact address in SECURITY.md. The address is Kev's ruling
    /// (#708 stays open for it).
    static let recipient = "hello@round-tower.ie"

    enum SendOutcome: Equatable {
        /// The mail app opened with the message filled in.
        case opened
        /// The link was over the cap: the mail app opened with the start of the body and the
        /// full text is on the clipboard.
        case copiedTruncated
        /// No app on this Mac handles mailto: links — the full text is on the clipboard instead.
        case copiedNoMailClient
        /// A mail app exists but would not open the link (too long for it, most likely): the
        /// full text is on the clipboard instead.
        case copiedCouldNotOpen
    }

    /// The redacted draft for one exchange. The brain is the answer's stamp, or the resident
    /// brain for a pre-trace turn. Redaction runs over the WHOLE body, the user's own question
    /// included — over-redaction is the safe direction, and the sheet lets them put a word back.
    /// The name the redactor removes is the display name from onboarding (what M1K3 greets the
    /// user by), read from the key `saveFirstRunName` writes.
    static func draft(exchange: AnswerExchange, note: String?, fallbackBrain: String) -> FieldReportDraft {
        let report = FieldReport(
            question: exchange.question,
            answer: exchange.answer,
            brain: exchange.brain ?? fallbackBrain,
            appVersion: infoString("CFBundleShortVersionString"),
            build: infoString("CFBundleVersion"),
            note: note
        )
        // Same scrub, same order, as the issue report: PII first, then the honeypot pass.
        let displayName = UserDefaults.standard.string(forKey: AppEnvironment.userDisplayNameKey)
        let redactor = DiagnosticRedactor(homeDirectory: NSHomeDirectory(), userName: displayName)
        let body = CanaryGuard.fromLocalConfig().scan(redactor.redact(FieldReportFormatter.body(report))).text
        return FieldReportDraft(subject: FieldReportFormatter.subject(report), body: body)
    }

    /// Open the user's mail app with the message filled in. Called from the sheet's Send
    /// button and nowhere else. The full body rides the clipboard whenever the link cannot.
    @MainActor
    static func send(subject: String, body: String) -> SendOutcome {
        guard let built = MailtoURL.compose(to: recipient, subject: subject, body: body) else {
            copy(body)
            return .copiedNoMailClient
        }
        if built.truncated { copy(body) }
        guard NSWorkspace.shared.urlForApplication(toOpen: built.url) != nil else {
            copy(body)
            return .copiedNoMailClient
        }
        guard NSWorkspace.shared.open(built.url) else {
            copy(body)
            return .copiedCouldNotOpen
        }
        return built.truncated ? .copiedTruncated : .opened
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
