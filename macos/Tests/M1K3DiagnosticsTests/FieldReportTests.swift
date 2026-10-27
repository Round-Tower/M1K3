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

//  Review: Kev + claude-opus-5.5, 2026-10-26 (code-review fold) — the scrub is tested where it runs:
//  `redactedBody` (format, then DiagnosticRedactor over the whole body, then the injected honeypot scrub on
//  the REDACTED text) across question, answer and note; the mailto link keeps its two keys against an
//  injected body, normalises a pasted CRLF, and stays under the encoded cap on a head-dense body. Confidence 0.85.
//  Review: Kev + claude-opus-5.5, 2026-10-27 (bot review fold) — the redactor runs over the user's fields only
//  (question, answer, note), then the body is formatted: a display name that is one of M1K3's own words
//  ("Lil", "May", "Read", "Your") left "Brain: [name]" and a mangled preamble when the whole body was
//  redacted. Confidence 0.85.
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

    private static let leaky = FieldReport(
        question: "Why does /Users/kev/Documents/plan.md say to mail kev@example.com?",
        answer: "Because Kev wrote it that way; /Users/aoife/Desktop/old.md disagrees, and the plan is in Documents.",
        brain: "Big", appVersion: "1.2.1", build: "540", note: "Kev asked aoife@example.ie"
    )

    @Test("redact each field, format, scrub: paths, emails and the name leave question, answer AND note")
    func redactScrubsEveryUserField() {
        let body = FieldReportFormatter.redactedBody(Self.leaky, homeDirectory: "/Users/kev", userName: "Kev")
        #expect(!body.contains("/Users/kev"))
        #expect(body.contains("~/Documents/plan.md"), "this Mac's home path collapses to ~")
        #expect(body.contains("/Users/[user]/Desktop/old.md"), "another account's path loses its name, keeps its shape")
        #expect(!body.contains("kev@example.com"))
        #expect(!body.contains("aoife@example.ie"), "the note is scrubbed too")
        #expect(!body.lowercased().contains("kev"), "the display name goes, whole word, any case")
        #expect(body.contains("[name] wrote it that way"))
        #expect(body.contains("What was off: [name] asked [email]"))
        #expect(body.contains("the plan is in Documents"))
        #expect(body.contains("may quote what M1K3 read"), "the preamble is M1K3's own copy and is never redacted")
        // The subject is built apart from the body and never carries the user's words.
        let subject = FieldReportFormatter.subject(Self.leaky)
        #expect(subject == "M1K3 field report: Big 1.2.1 (540)")
    }

    @Test("a display name that is one of M1K3's own words leaves M1K3's copy alone: only the user's fields lose it")
    func nameScrubLeavesM1K3sOwnCopyAlone() {
        // Each name is a word in the preamble, a label or the Brain/App line. Redacting the whole
        // formatted body turned "Brain: Lil" into "Brain: [name]" for a user called Lil.
        for name in ["Lil", "May", "Read", "Your", "What", "App", "Brain"] {
            let named = FieldReport(
                question: "I'm \(name).", answer: "Hello \(name)!", brain: "Lil",
                appVersion: "1.2.1", build: "540", note: "\(name) here"
            )
            let body = FieldReportFormatter.redactedBody(named, homeDirectory: "/Users/kev", userName: name)
            // Exactly the plain format of the scrubbed fields: every line M1K3 wrote is untouched.
            let expected = FieldReportFormatter.body(FieldReport(
                question: "I'm [name].", answer: "Hello [name]!", brain: "Lil",
                appVersion: "1.2.1", build: "540", note: "[name] here"
            ))
            #expect(body == expected, "the name \(name) reached M1K3's own copy")
        }
    }

    @Test("no display name, or a blank one, removes no word")
    func nameScrubIsANoOpWithoutAName() {
        for name in [nil, "", "   "] as [String?] {
            let body = FieldReportFormatter.redactedBody(Self.leaky, homeDirectory: "/Users/kev", userName: name)
            #expect(body.contains("Because Kev wrote it"), "name \(String(describing: name)) removed a word")
            #expect(body.contains("[email]"), "the email rule runs whatever the name")
        }
    }

    @Test("the extra scrub reads the REDACTED body (the DiagnosticsReportBuilder order); its output is what is sent")
    func extraScrubRunsAfterTheRedactor() throws {
        var seen: String?
        let body = FieldReportFormatter.redactedBody(Self.leaky, homeDirectory: "/Users/kev", userName: "Kev") { text in
            seen = text
            return text + "\n<scrubbed>"
        }
        let input = try #require(seen)
        #expect(!input.contains("/Users/kev"))
        #expect(!input.contains("kev@example.com"))
        #expect(input.contains("[name] wrote it"))
        #expect(body == input + "\n<scrubbed>")
    }

    @Test("a honeypot planted in the question, the answer or the note comes out as [REDACTED]")
    func plantedCanaryIsRedactedInEveryField() {
        let canary = "tripwire-7f3a"
        let planted = FieldReport(
            question: "what is \(canary)?", answer: "It is \(canary).", brain: "Lil",
            appVersion: "1.2.1", build: "540", note: "it said \(canary)"
        )
        // The app passes CanaryGuard.fromLocalConfig().scan(_:).text (M1K3Chat); this stand-in has its shape.
        let body = FieldReportFormatter.redactedBody(planted, homeDirectory: "/Users/kev", userName: nil) {
            $0.replacingOccurrences(of: canary, with: "[REDACTED]")
        }
        #expect(!body.contains(canary))
        #expect(body.components(separatedBy: "[REDACTED]").count - 1 == 3)
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
        let items = components.queryItems ?? []
        #expect(items.map(\.name) == ["subject", "body"])
        #expect(items.first?.value == "M1K3 field report: Lil 1.2.1 (540)")
        // RFC 6068 §5: the body's line breaks go out as CRLF, everything else byte for byte.
        #expect(items.last?.value == body.replacingOccurrences(of: "\n", with: "\r\n"))
        // Raw spaces, ampersands, pluses and newlines never ride the link unencoded — a mail
        // client would read them as separators or drop them.
        let raw = built.url.absoluteString
        #expect(!raw.contains(" "))
        #expect(!raw.contains("\n"))
        #expect(raw.components(separatedBy: "&").count == 2, "the one & is the link's own, between subject and body")
        #expect(!raw.contains("+"))
        #expect(raw.contains("%0D%0A"))
    }

    @Test("a body cannot change the link: an injected cc, bcc, subject or fragment stays inside body=")
    func injectedBodyStaysInsideTheBody() throws {
        // An answer can be prompt-injected; this is the shape an injection would try.
        let body = "x&bcc=evil@example.com&cc=a?subject=z#frag\r\nBcc: e@x.io"
        let built = try #require(MailtoURL.compose(to: "hello@round-tower.ie", subject: "s", body: body))
        let raw = built.url.absoluteString
        #expect(raw.components(separatedBy: "&").count == 2)
        #expect(raw.components(separatedBy: "?").count == 2)
        #expect(!raw.contains("#"))
        let components = try #require(URLComponents(url: built.url, resolvingAgainstBaseURL: false))
        #expect(components.path == "hello@round-tower.ie")
        #expect(components.queryItems?.map(\.name) == ["subject", "body"])
        #expect(components.queryItems?.last?.value == body, "the body round-trips byte for byte")
    }

    @Test("a pasted CRLF is not doubled: every line break goes out as exactly one %0D%0A")
    func pastedCRLFIsNormalised() throws {
        let built = try #require(MailtoURL.compose(to: "a@b.ie", subject: "s", body: "a\r\nb\nc"))
        let raw = built.url.absoluteString
        #expect(!raw.contains("%0D%0D"))
        #expect(raw.components(separatedBy: "%0A").count == raw.components(separatedBy: "%0D%0A").count, "no bare LF")
        let components = try #require(URLComponents(url: built.url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.last?.value == "a\r\nb\r\nc")
    }

    @Test("a head-dense body (wide text first, ASCII after) still ends under the encoded cap, its head kept")
    func headDenseBodyEndsUnderTheEncodedCap() throws {
        // 12,000 characters: under the character cap, about 52 KB once percent-encoded.
        let body = String(repeating: "日", count: 5000) + String(repeating: "x", count: 7000)
        let built = try #require(MailtoURL.compose(to: "a@b.ie", subject: "s", body: body))
        #expect(built.truncated)
        let encodedBody = try #require(built.url.absoluteString.components(separatedBy: "&body=").last)
        #expect(encodedBody.utf8.count <= 24000, "the body segment never exceeds the encoded cap")
        let components = try #require(URLComponents(url: built.url, resolvingAgainstBaseURL: false))
        let sent = try #require(components.queryItems?.last?.value)
        #expect(sent.hasPrefix("日日日"))
        #expect(sent.contains("clipboard"))
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
