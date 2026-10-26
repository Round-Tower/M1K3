//
//  FieldReport.swift
//  M1K3Diagnostics
//
//  The opt-in "Send this exchange" payload (#708) and its transport half. The evals measure
//  Kev's fixtures, not users' conversations; a thumbs-down can now offer to email that ONE
//  exchange to Round Tower. The value here is the whole of what leaves: the user's message,
//  M1K3's answer, the brain that wrote it, the app version and build, and the user's own note.
//  Never sources, reasoning, tool names, memories, documents or another turn — the stored
//  properties ARE the contract, and FieldReportTests pins the set by reflection.
//
//  Transport is a mailto: link the user's own mail app opens (no new network path; their Sent
//  folder is the record). `MailtoURL` mirrors `GitHubIssueURL`: a capped, percent-encoded link
//  and a `truncated` flag so the app can put the full text on the clipboard. Redaction is NOT
//  here: the shell runs `DiagnosticRedactor` and then `CanaryGuard` over the formatted body
//  (the `DiagnosticsReportBuilder` order), and a test pins redact-then-format.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-26, Confidence 0.85 (pure, TDD-pinned incl. the
//  field set and the cap; the mail-app hand-off and the real mailto length ceiling are
//  verify-by-launch). Prior: none (new file).
//

import Foundation

/// Exactly one exchange, as the user will see it in the sheet before anything leaves.
public struct FieldReport: Sendable, Equatable {
    public var question: String
    public var answer: String
    /// The brain's display name ("Lil", "Big", "Mini") — the stamp on the answer, or the
    /// shell's fallback for a pre-trace turn.
    public var brain: String
    public var appVersion: String
    public var build: String
    /// The user's thumbs-down note, when they wrote one.
    public var note: String?

    public init(question: String, answer: String, brain: String, appVersion: String, build: String, note: String?) {
        self.question = question
        self.answer = answer
        self.brain = brain
        self.appVersion = appVersion
        self.build = build
        self.note = note
    }
}

public enum FieldReportFormatter {
    /// The email body: what it contains and what it does not, then the exchange. Plain text —
    /// mail clients render mailto bodies verbatim, so no markdown.
    public static func body(_ report: FieldReport) -> String {
        var lines = [
            "This email contains one exchange from M1K3: your message, M1K3's answer, the brain that wrote it, and the app version.",
            "It does not contain memories, documents, sources, tool names or other turns — nothing else from your Mac.",
            "",
            "Your message:",
            report.question,
            "",
            "M1K3's answer:",
            report.answer,
            "",
            "Brain: \(report.brain) · App: \(report.appVersion) (\(report.build))",
        ]
        if let note = report.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            lines.append("What was off: \(note)")
        }
        return lines.joined(separator: "\n")
    }

    /// The subject names only the brain and the version — never the user's words.
    public static func subject(_ report: FieldReport) -> String {
        "M1K3 field report: \(report.brain) \(report.appVersion) (\(report.build))"
    }
}

public enum MailtoURL {
    public struct Built: Sendable, Equatable {
        public let url: URL
        /// True when the body exceeded the cap and was cut — the caller should put the full
        /// body on the clipboard and say so.
        public let truncated: Bool
    }

    /// RFC 3986 unreserved characters: everything else in the subject and body is
    /// percent-encoded, so `&`, `=`, `+`, `?` and newlines never read as link syntax (RFC 6068
    /// treats a bare `+` as a plus, but some clients do not; encoding it is the safe side).
    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Build `mailto:<to>?subject=…&body=…`. Launch Services and mail clients cap URL length,
    /// so an over-long body is cut and flagged; the full text is meant to ride the clipboard.
    public static func compose(to: String, subject: String, body: String, maxBodyChars: Int = 12000) -> Built? {
        var body = body
        var truncated = false
        if body.count > maxBodyChars {
            body = String(body.prefix(maxBodyChars))
                + "\n\n… cut here — the full text is on your clipboard. Paste it into this email."
            truncated = true
        }
        guard let recipient = to.addingPercentEncoding(withAllowedCharacters: unreserved.union(CharacterSet(charactersIn: "@"))),
              let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: unreserved),
              let encodedBody = body.addingPercentEncoding(withAllowedCharacters: unreserved),
              let url = URL(string: "mailto:\(recipient)?subject=\(encodedSubject)&body=\(encodedBody)")
        else { return nil }
        return Built(url: url, truncated: truncated)
    }
}
