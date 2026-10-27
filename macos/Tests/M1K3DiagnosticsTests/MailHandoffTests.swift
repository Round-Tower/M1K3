//
//  MailHandoffTests.swift
//  M1K3DiagnosticsTests
//
//  The "Send by email" decision (#708), with the OS behind a fake: whether the link was built,
//  whether any app handles mailto:, whether it opened. The rule that matters is the clipboard.
//  The full body goes there on every outcome but a whole link opened, BEFORE the mail app takes
//  the front, and a missing link is never told to the user as a missing mail app.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-26, Confidence 0.85 (pure; the live NSWorkspace and
//  NSPasteboard calls are verify-by-launch, UNVERIFIED this run). Prior: none (new file).
//

import Foundation
@testable import M1K3Diagnostics
import Testing

/// Records every OS call in order, and answers the two questions as told.
@MainActor
private final class FakeMail: MailOpening {
    enum Call: Equatable {
        case handler(URL), open(URL), copy(String)
    }

    var calls: [Call] = []
    let handles: Bool
    let opens: Bool

    init(handles: Bool = true, opens: Bool = true) {
        self.handles = handles
        self.opens = opens
    }

    func hasHandler(for url: URL) -> Bool {
        calls.append(.handler(url))
        return handles
    }

    func open(_ url: URL) -> Bool {
        calls.append(.open(url))
        return opens
    }

    func copy(_ text: String) {
        calls.append(.copy(text))
    }

    var copies: [String] {
        calls.compactMap { if case let .copy(text) = $0 { text } else { nil } }
    }

    var opened: Bool {
        calls.contains { if case .open = $0 { true } else { false } }
    }
}

@MainActor
struct MailHandoffTests {
    private static let body = "Your message:\nWhy?\n\nM1K3's answer:\nBecause."
    private static let whole = MailtoURL.Built(
        url: URL(string: "mailto:a@b.ie?subject=s&body=whole")!, truncated: false
    )
    private static let cut = MailtoURL.Built(url: URL(string: "mailto:a@b.ie?subject=s&body=cut")!, truncated: true)

    @Test("a whole link that opens: the mail app has everything, the clipboard is left alone")
    func wholeLinkOpens() {
        let mail = FakeMail()
        #expect(MailHandoff.send(link: Self.whole, body: Self.body, via: mail) == .opened)
        #expect(mail.calls == [.handler(Self.whole.url), .open(Self.whole.url)])
    }

    @Test("a cut link: the FULL body is on the clipboard before the mail app opens")
    func cutLinkCopiesBeforeOpening() {
        let mail = FakeMail()
        #expect(MailHandoff.send(link: Self.cut, body: Self.body, via: mail) == .copiedTruncated)
        #expect(mail.calls == [.handler(Self.cut.url), .copy(Self.body), .open(Self.cut.url)])
    }

    @Test("no app handles mailto: the body is copied, and nothing is asked to open")
    func noHandlerCopiesAndNeverOpens() {
        for link in [Self.whole, Self.cut] {
            let mail = FakeMail(handles: false)
            #expect(MailHandoff.send(link: link, body: Self.body, via: mail) == .copiedNoMailClient)
            #expect(mail.copies == [Self.body])
            #expect(!mail.opened)
        }
    }

    @Test("a mail app that refuses the link: the body is copied once, whether or not the link was cut")
    func refusedOpenCopiesOnce() {
        for link in [Self.whole, Self.cut] {
            let mail = FakeMail(opens: false)
            #expect(MailHandoff.send(link: link, body: Self.body, via: mail) == .copiedCouldNotOpen)
            #expect(mail.copies == [Self.body])
        }
    }

    @Test("a link that could not be built is a could-not-open, never 'no mail app': copied, nothing asked of the OS")
    func unbuiltLinkIsCouldNotOpen() {
        let mail = FakeMail()
        #expect(MailHandoff.send(link: nil, body: Self.body, via: mail) == .copiedCouldNotOpen)
        #expect(mail.calls == [.copy(Self.body)])
    }
}
