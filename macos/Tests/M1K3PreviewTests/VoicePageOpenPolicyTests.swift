//
//  VoicePageOpenPolicyTests.swift
//  M1K3PreviewTests
//
//  "A page never opens on its own" (#839), pinned at the policy layer: only a tap on a link
//  chip or a spoken request opens a page; a request that came from model output alone never
//  does, whatever the URL. Every load that is allowed is judged by `WebURLPolicy` first.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-15, Confidence 0.85. Prior: none (new file).

import Foundation
@testable import M1K3Preview
import Synchronization
import Testing

struct VoicePageOpenPolicyTests {
    private struct Table: HostResolving {
        let answers: [String: [String]]
        let calls = Counter()
        func addresses(for host: String) async -> [String]? {
            calls.bump()
            return answers[host] ?? ["93.184.216.34"]
        }
    }

    private final class Counter: Sendable {
        private let count = Mutex(0)
        func bump() {
            count.withLock { $0 += 1 }
        }

        var value: Int {
            count.withLock { $0 }
        }
    }

    private func request(_ origin: VoicePageOpenRequest.Origin, _ raw: String, quote: String? = nil)
        -> VoicePageOpenRequest
    {
        VoicePageOpenRequest(origin: origin, url: URL(string: raw) ?? URL(fileURLWithPath: "/"), quote: quote)
    }

    @Test("a tap on a link chip opens a public page")
    func chipTapOpens() async throws {
        let decision = await VoicePageOpenPolicy.decide(request(.linkChipTap, "https://example.com/a"), resolver: Table(answers: [:]))
        #expect(try decision == .open(#require(URL(string: "https://example.com/a"))))
    }

    @Test("a spoken request opens a public page")
    func spokenRequestOpens() async throws {
        let decision = await VoicePageOpenPolicy.decide(request(.spokenRequest, "https://example.com/a"), resolver: Table(answers: [:]))
        #expect(try decision == .open(#require(URL(string: "https://example.com/a"))))
    }

    @Test("model output alone never opens a page, and never even resolves the host", arguments: [
        "https://example.com", "https://en.wikipedia.org/wiki/Fox", "http://93.184.216.34/",
    ])
    func modelOutputNeverOpens(raw: String) async {
        let resolver = Table(answers: [:])
        let decision = await VoicePageOpenPolicy.decide(request(.modelOutput, raw), resolver: resolver)
        #expect(decision == .refused(.notAskedFor))
        #expect(resolver.calls.value == 0)
    }

    @Test("a private or local address is refused even when asked for", arguments: [
        "http://localhost:3000", "http://192.168.1.1/admin", "http://169.254.169.254/latest", "file:///etc/hosts",
    ])
    func privateRefused(raw: String) async throws {
        let decision = await VoicePageOpenPolicy.decide(request(.linkChipTap, raw), resolver: Table(answers: [:]))
        #expect(try decision != .open(#require(URL(string: raw))))
        #expect(decision == .refused(.notWebPage) || decision == .refused(.privateAddress))
    }

    @Test("a public name that resolves into private space is refused")
    func rebindingRefused() async {
        let resolver = Table(answers: ["sneaky.example.com": ["93.184.216.34", "10.0.0.5"]])
        let decision = await VoicePageOpenPolicy.decide(request(.spokenRequest, "https://sneaky.example.com"), resolver: resolver)
        #expect(decision == .refused(.privateAddress))
    }

    @Test("a non-web scheme is refused as not a web page", arguments: [
        "javascript:alert(1)", "ftp://example.com/x", "m1k3://event/x", "file:///etc/hosts",
    ])
    func nonWebRefused(raw: String) async {
        let decision = await VoicePageOpenPolicy.decide(request(.linkChipTap, raw), resolver: Table(answers: [:]))
        #expect(decision == .refused(.notWebPage))
    }

    @Test("an allowed open carries the quote as a text fragment")
    func quoteBecomesFragment() async {
        let decision = await VoicePageOpenPolicy.decide(
            request(.linkChipTap, "https://example.com/a", quote: "fox jumps"), resolver: Table(answers: [:])
        )
        guard case let .open(url) = decision else {
            Issue.record("expected open, got \(decision)")
            return
        }
        #expect(url.absoluteString == "https://example.com/a#:~:text=fox%20jumps")
    }

    // MARK: - The session

    @Test("the session opens on a tap, and a model-originated request leaves it closed with no notice")
    @MainActor
    func sessionOpensOnlyWhenAsked() async {
        let session = VoicePageSession(resolver: Table(answers: [:]))
        await session.open(request(.modelOutput, "https://example.com"))
        #expect(session.url == nil)
        #expect(session.isOpen == false)

        await session.open(request(.linkChipTap, "https://example.com"))
        #expect(session.url?.absoluteString == "https://example.com")
        #expect(session.isOpen)
    }

    @Test("a refused request leaves the session as it was and says why")
    @MainActor
    func sessionRefusal() async {
        let session = VoicePageSession(resolver: Table(answers: [:]))
        await session.open(request(.linkChipTap, "https://example.com/one"))
        await session.open(request(.linkChipTap, "http://192.168.0.1"))
        #expect(session.url?.absoluteString == "https://example.com/one")
        #expect(session.refusal == .privateAddress)
        // The next good open clears the note.
        await session.open(request(.spokenRequest, "https://example.com/two"))
        #expect(session.refusal == nil)
    }

    @Test("close clears the page and any note")
    @MainActor
    func sessionClose() async {
        let session = VoicePageSession(resolver: Table(answers: [:]))
        await session.open(request(.linkChipTap, "https://example.com"))
        session.close()
        #expect(session.url == nil)
        #expect(session.refusal == nil)
    }
}
