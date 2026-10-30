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
//  and a `truncated` flag so the app can put the full text on the clipboard (`MailHandoff`).
//  The scrub is `FieldReportFormatter.redactedBody`: `DiagnosticRedactor` over each of the
//  user's fields (question, answer, note), then the format, then the injected extra scrub over
//  the whole body (the app passes CanaryGuard, which lives in M1K3Chat). Redact first, extra
//  scrub second is the `DiagnosticsReportBuilder` order and seam, unit-pinned here; the shell
//  only supplies the home path, the display name and the closure.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-26, Confidence 0.85 (pure, TDD-pinned incl. the
//  field set and the cap; the mail-app hand-off and the real mailto length ceiling are
//  verify-by-launch). Prior: none (new file).
//  Review: Kev + claude-fable-5.1, 2026-10-26 (pre-push review fold) — the preamble claims only what the field set
//  guarantees (the answer may quote what M1K3 read); body line breaks go out as CRLF (RFC 6068 §5); the cap is
//  also on ENCODED bytes, since a non-ASCII scalar costs 3–12 bytes in the link. Confidence 0.85.
//  Review: Kev + claude-opus-5.5, 2026-10-26 (code-review fold) — `redactedBody` moves the scrub out of
//  the app glue (it ran under TDD_SKIP, pinned only by a string scan) into this pure, tested seam; the
//  header now says the order the code runs (format, redact, scrub). Confidence 0.85.
//  Review: Kev + claude-opus-5.5, 2026-10-27 (bot review fold) — the redactor runs over the user's fields, not the
//  formatted body: a display name that is one of M1K3's own words ("Lil", "May", "Read", "Your") turned the Brain
//  line into "Brain: [name]" and mangled the preamble. The canary pass still reads the whole body. Confidence 0.85.
//  Review: Kev + claude-opus-5.5, 2026-10-30 — the subject takes Round Tower's support format, through
//  `RoundTowerReports.subject`. Confidence 0.85.
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
            "This email contains one exchange from M1K3: your message, M1K3's answer, your note, the brain that wrote it, and the app version.",
            "It does not contain other turns, tool names, attachments, or your memories and documents themselves. The answer may quote what M1K3 read to write it, so read it over before you send.",
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

    /// The body as the sheet shows it and the link carries it. `DiagnosticRedactor` runs over
    /// each field the user or the model wrote (the question, the answer, the note): this Mac's
    /// home path to `~`, other `/Users/<name>` paths, email addresses, the user's display name.
    /// Then `body(_:)` formats them, and `scrubExtra` runs on the whole REDACTED body; the app
    /// passes CanaryGuard's honeypot scan. The preamble, the labels and the Brain/App line are
    /// M1K3's own and are never redacted, so a user called "Lil" or "May" cannot mangle them.
    /// Over-redaction of the user's fields is the safe direction, and the sheet lets the user
    /// put a word back.
    public static func redactedBody(
        _ report: FieldReport,
        homeDirectory: String,
        userName: String?,
        scrubExtra: (String) -> String = { $0 }
    ) -> String {
        let redactor = DiagnosticRedactor(homeDirectory: homeDirectory, userName: userName)
        var scrubbed = report
        scrubbed.question = redactor.redact(report.question)
        scrubbed.answer = redactor.redact(report.answer)
        scrubbed.note = report.note.map(redactor.redact)
        return scrubExtra(body(scrubbed))
    }

    /// Round Tower's support subject, never the user's words. The shell names the platform: it
    /// is no part of the report's contract, the stored properties.
    public static func subject(_ report: FieldReport, platform: String) -> String {
        RoundTowerReports.subject(platform: platform, version: report.appVersion)
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

    private static let cutTail = "\n\n… cut here — the full text is on your clipboard. Paste it into this email."

    /// Build `mailto:<to>?subject=…&body=…`. Launch Services and mail clients cap URL length,
    /// so an over-long body is cut and flagged; the full text is meant to ride the clipboard.
    /// Two caps: characters (what the user reads) and ENCODED bytes (what the link carries — a
    /// CJK or emoji scalar costs 3–12 bytes once percent-encoded). Neither figure is measured
    /// against a real client yet; both err short, and the clipboard holds the whole text.
    public static func compose(
        to: String, subject: String, body: String, maxBodyChars: Int = 12000, maxEncodedBytes: Int = 24000
    ) -> Built? {
        var keep = min(body.count, maxBodyChars)
        var truncated = body.count > maxBodyChars
        guard var encodedBody = encode(truncated ? String(body.prefix(keep)) + cutTail : body) else { return nil }
        // Shrink proportionally until the encoded body fits; `keep` strictly falls each pass.
        while encodedBody.utf8.count > maxEncodedBytes, keep > 0 {
            keep = keep * maxEncodedBytes / encodedBody.utf8.count
            truncated = true
            guard let shorter = encode(String(body.prefix(keep)) + cutTail) else { return nil }
            encodedBody = shorter
        }
        guard let recipient = to.addingPercentEncoding(withAllowedCharacters: unreserved.union(CharacterSet(charactersIn: "@"))),
              let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: unreserved),
              let url = URL(string: "mailto:\(recipient)?subject=\(encodedSubject)&body=\(encodedBody)")
        else { return nil }
        return Built(url: url, truncated: truncated)
    }

    /// RFC 6068 §5: body line breaks are `%0D%0A`. Mail.app forgives a bare LF; other clients
    /// run the lines together or stop at the first one.
    private static func encode(_ text: String) -> String? {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
            .addingPercentEncoding(withAllowedCharacters: unreserved)
    }
}
