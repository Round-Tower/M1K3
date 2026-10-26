//
//  FieldReportTests.swift
//  M1K3DiagnosticsTests
//
//  The opt-in "Send this exchange" payload (#708): exactly one exchange and nothing else, as a
//  plain-text email body plus the mailto: link the user's own mail app opens. The field-set pin
//  is the issue's gate — "the payload builder takes only the one exchange" — held structurally,
//  so a sources / memory / tools field cannot be added without this file noticing.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-26, Confidence 0.85 (pure; the mail-app hand-off is
//  verify-by-launch). Prior: none (new file).
//  Review: Kev + claude-fable-5.1, 2026-10-26 (pre-push review fold) — pins the honest preamble, CRLF body
//  line breaks, and the encoded-byte cap on a CJK body. Confidence 0.85.
//

import Foundation
@testable import M1K3Diagnostics
import Testing

private func report(note: String? = "it should have searched the web") -> FieldReport {
    FieldReport(
        question: "Who won the hurling final?",
        answer: "I don't have that result to hand.",
        brain: "Lil",
        appVersion: "1.2.1",
        build: "540",
        note: note
    )
}

struct FieldReportTests {
    @Test("the payload is exactly the one exchange: question, answer, brain, app version, build, note")
    func fieldSetIsExactlyTheOneExchange() {
        let labels = Mirror(reflecting: report()).children.compactMap(\.label)
        #expect(labels == ["question", "answer", "brain", "appVersion", "build", "note"])
    }

    @Test("the body carries the four fields and the note, and says what it does not carry")
    func bodyCarriesTheFourFieldsAndTheNote() {
        let body = FieldReportFormatter.body(report())
        #expect(body.contains("Who won the hurling final?"))
        #expect(body.contains("I don't have that result to hand."))
        #expect(body.contains("Brain: Lil"))
        #expect(body.contains("App: 1.2.1 (540)"))
        #expect(body.contains("What was off: it should have searched the web"))
        #expect(body.contains("does not contain"))
        for absent in ["memories", "documents", "other turns", "tool names"] {
            #expect(body.contains(absent), "the preamble names \(absent) as left out")
        }
        // Truth in copy: a cited answer can quote the user's own document, so the preamble
        // claims only what the field set guarantees and says so.
        #expect(body.contains("may quote what M1K3 read"))
        #expect(!body.contains("nothing else from your Mac"))
    }

    @Test("no note, no 'What was off' line — a blank note is the same as none")
    func noteIsOptional() {
        #expect(!FieldReportFormatter.body(report(note: nil)).contains("What was off"))
        #expect(!FieldReportFormatter.body(report(note: "   ")).contains("What was off"))
    }

    @Test("the subject names the brain and the version, never the user's words")
    func subjectIsBrainAndVersion() {
        #expect(FieldReportFormatter.subject(report()) == "M1K3 field report: Lil 1.2.1 (540)")
    }

    @Test("redact then format scrubs a home path, an email and the profile name; the answer survives")
    func redactThenFormatScrubsPathsEmailsAndName() {
        let leaky = FieldReport(
            question: "Why does /Users/kev/Documents/plan.md say to mail kev@example.com?",
            answer: "Because Kev wrote it that way, and the plan is in Documents.",
            brain: "Big", appVersion: "1.2.1", build: "540", note: "Kev asked"
        )
        let redactor = DiagnosticRedactor(homeDirectory: "/Users/kev", userName: "Kev")
        let body = redactor.redact(FieldReportFormatter.body(leaky))
        #expect(!body.contains("/Users/kev"))
        #expect(body.contains("~/Documents/plan.md"))
        #expect(!body.contains("kev@example.com"))
        #expect(body.contains("[email]"))
        #expect(!body.lowercased().contains("kev"))
        #expect(body.contains("[name] wrote it that way"))
        #expect(body.contains("What was off: [name] asked"))
        #expect(body.contains("the plan is in Documents"))
    }
}

struct MailtoURLTests {
    @Test("a short body builds an encoded mailto: whose recipient, subject and body round-trip")
    func shortBodyBuildsAnEncodedMailto() throws {
        let body = "Line one & two\nLine three: 50% + more?"
        let built = try #require(MailtoURL.compose(
            to: "hello@round-tower.ie", subject: "M1K3 field report: Lil 1.2.1 (540)", body: body
        ))
        #expect(!built.truncated)
        #expect(built.url.scheme == "mailto")
        let components = try #require(URLComponents(url: built.url, resolvingAgainstBaseURL: false))
        #expect(components.path == "hello@round-tower.ie")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(items["subject"] == "M1K3 field report: Lil 1.2.1 (540)")
        // RFC 6068 §5: the body's line breaks go out as CRLF, everything else byte for byte.
        #expect(items["body"] == body.replacingOccurrences(of: "\n", with: "\r\n"))
        // Raw spaces, ampersands, pluses and newlines never ride the link unencoded — a mail
        // client would read them as separators or drop them.
        let raw = built.url.absoluteString
        #expect(!raw.contains(" "))
        #expect(!raw.contains("\n"))
        #expect(!raw.contains("&two"))
        #expect(!raw.contains("+"))
        #expect(raw.contains("%0D%0A"))
    }

    @Test("the cap is also on encoded bytes: a CJK body under the character cap is still cut to fit the link")
    func encodedByteCapCutsAWideBody() throws {
        let wide = String(repeating: "日", count: 10000) // 10,000 chars, ~90 KB once percent-encoded
        let built = try #require(MailtoURL.compose(to: "a@b.ie", subject: "s", body: wide))
        #expect(built.truncated)
        #expect(built.url.absoluteString.utf8.count <= 24000 + 100, "the link stays within the encoded cap")
        let components = try #require(URLComponents(url: built.url, resolvingAgainstBaseURL: false))
        let sent = try #require(components.queryItems?.first { $0.name == "body" }?.value)
        #expect(sent.hasPrefix("日日日"))
        #expect(sent.contains("clipboard"))
        // A short wide body is sent whole.
        let short = try #require(MailtoURL.compose(to: "a@b.ie", subject: "s", body: String(repeating: "日", count: 50)))
        #expect(!short.truncated)
    }

    @Test("an over-long body is cut, flagged, and says the full text is on the clipboard")
    func overLongBodyIsTruncatedAndFlagged() throws {
        let huge = String(repeating: "x", count: 10000)
        let built = try #require(MailtoURL.compose(
            to: "hello@round-tower.ie", subject: "Big", body: huge, maxBodyChars: 100
        ))
        #expect(built.truncated)
        let components = try #require(URLComponents(url: built.url, resolvingAgainstBaseURL: false))
        let sent = try #require(components.queryItems?.first { $0.name == "body" }?.value)
        #expect(sent.hasPrefix(String(repeating: "x", count: 100)))
        #expect(sent.contains("clipboard"))
        #expect(sent.count < 400, "the cut body is the cap plus a one-line tail")
    }

    @Test("a body under the cap is sent whole — the cap is a ceiling, not a trim")
    func bodyAtTheCapIsWhole() throws {
        let exact = String(repeating: "y", count: 100)
        let built = try #require(MailtoURL.compose(to: "a@b.ie", subject: "s", body: exact, maxBodyChars: 100))
        #expect(!built.truncated)
        let components = try #require(URLComponents(url: built.url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first { $0.name == "body" }?.value == exact)
    }
}
