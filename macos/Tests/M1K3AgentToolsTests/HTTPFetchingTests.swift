//
//  HTTPFetchingTests.swift
//  M1K3AgentToolsTests
//
//  The redirect gate on the live fetcher (#210 / #266 review): a public origin
//  answering 302 → 10.0.0.1 must NOT be followed — URLSession follows 3xx by
//  default, and the resolve-before-fetch gate never sees the hop. Hermetic:
//  a URLProtocol stub plays the servers, a fake resolver plays DNS.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-10, Confidence 0.85, Prior: Unknown.
//  Review: Kev + claude-fable-5.1, 2026-09-11, Confidence 0.8 — the stub's 302 waits for the
//  gate's decision (grace, or `stopLoading` on a followed hop) instead of racing it: the redirect
//  tests timed out in three of four CI runs under the parallel suite, on master too. Test-only.
//  Review: Kev + claude-fable-5.1, 2026-09-12, Confidence 0.85 — the grace was still a wall-clock bet
//  on the cooperative pool dispatching the async delegate (-1001 twice more on #293's heads and on
//  #291's own master run); now the resolver stub SIGNALS the load whose target it was asked about,
//  and the 302 is delivered after that signal (inline decision + a bridge grace), never on a clock
//  from the hop. Per-load nonce target hosts key the signal under the parallel suite. Test-only.
//

import Foundation
@testable import M1K3AgentTools
import M1K3Preview
import os
import Testing

/// Scripted servers: public.example/hop → 302 to a private-resolving host;
/// public.example/hop-public → 302 to a public-resolving host whose /fine
/// answers 200 OK; the private host's /secret → 200 SECRET (must never be
/// reached through a redirect). Every redirect target carries a per-load
/// nonce (`private-7.example`, `public-9.example`) so the gate's lookup of
/// THAT host can be routed back to THIS load while other tests run alongside.
/// `@unchecked Sendable`: the delivery timers below capture `self` into
/// `@Sendable` dispatch blocks. Two pieces of mutable state: `stopped`, read
/// and written under `lock` in one step and never held across a client
/// callback; and `pendingRedirect`, written ONCE in `redirect(toHost:path:)`
/// strictly before `self` is published into `registry` (under its lock) and
/// read only from deliveries dispatched after a `registry` lock — the
/// unlock → lock → GCD enqueue chain is the happens-before edge. Keep that
/// order: registering first, or delivering outside a registry pass, breaks it.
private final class StubTransport: URLProtocol, @unchecked Sendable {
    /// How long a 302 waits after the gate has CONSULTED THE RESOLVER for its
    /// target before it is delivered as the final response. The resolver stub
    /// answers without suspending, so the rest of the decision (`follow` →
    /// the async delegate's return → CFNetwork's bridge) runs inline on the
    /// same thread; a followed hop then calls `stopLoading` within that
    /// window and the delivery becomes a no-op. This covers CFNetwork's own
    /// queue hop only — the cooperative-pool dispatch of the async delegate,
    /// which a loaded runner delayed past a wall-clock grace (-1001 in most CI
    /// runs, 2026-09-11 → 09-12, master included), is behind the signal.
    static let postDecisionGrace: DispatchTimeInterval = .milliseconds(250)
    /// Valve: a hop the gate refuses WITHOUT resolving (a non-http scheme, a
    /// literal) never signals; deliver the 302 anyway rather than hang to the
    /// session timeout. None of the scripted hops take this path.
    static let unsignalledValve: DispatchTimeInterval = .seconds(3)

    /// Flipped by `stopLoading` (a followed hop) OR by the delivery the
    /// moment it commits to the 302 — whichever wins, the other becomes a
    /// no-op. No lock is ever held across a client callback.
    private let lock = NSLock()
    private var stopped = false

    /// Loads waiting for the gate to look up their redirect target, by host,
    /// plus the nonce that makes each target host unique. One lock, one step.
    private struct Registry {
        var waiting: [String: [StubTransport]] = [:]
        var nonce = 0
    }

    private static let registry = OSAllocatedUnfairLock(initialState: Registry())

    /// The resolver stub calls this (synchronously, before it answers) for
    /// every host the gate asks about; a waiting load for that host delivers
    /// its 302 after `postDecisionGrace`.
    static func gateConsulted(_ host: String) {
        let loads = registry.withLock { $0.waiting.removeValue(forKey: host) ?? [] }
        for load in loads {
            DispatchQueue.global().asyncAfter(deadline: .now() + postDecisionGrace) { load.deliverPendingRedirect() }
        }
    }

    private static func nextNonce() -> Int {
        registry.withLock { $0.nonce += 1; return $0.nonce }
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func stopLoading() {
        lock.withLock { stopped = true }
    }

    /// The 302 held back until the gate has decided (see `redirect(toHost:path:)`).
    private var pendingRedirect: HTTPURLResponse?

    private func deliverPendingRedirect() {
        // Check and commit in one locked step so a late `stopLoading` is a
        // no-op and a stale 302 never reaches a load the session abandoned.
        let shouldDeliver = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            stopped = true
            return true
        }
        guard shouldDeliver, let response = pendingRedirect, let client else { return }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: Data("redirecting".utf8))
        client.urlProtocolDidFinishLoading(self)
    }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        func respond(_ status: Int, _ body: String, headers: [String: String] = [:]) {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: Data(body.utf8))
            client.urlProtocolDidFinishLoading(self)
        }
        func redirect(toHost host: String, path: String) {
            let target = URL(string: "https://\(host)\(path)")!
            let response = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString]
            )!
            pendingRedirect = response
            // Register BEFORE announcing the hop: the gate may consult the
            // resolver on the announcing thread before this call returns.
            Self.registry.withLock { $0.waiting[host, default: []].append(self) }
            client.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            // If the session declines the hop, this 302 is the final answer —
            // delivered once the gate has decided (`gateConsulted`), or by the
            // valve. A followed hop calls `stopLoading` on this load first.
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.unsignalledValve) { [self] in
                Self.registry.withLock { $0.waiting.removeValue(forKey: host) }
                deliverPendingRedirect()
            }
        }
        let host = url.host ?? ""
        switch (host, url.path) {
        case ("public.example", "/hop"): redirect(toHost: "private-\(Self.nextNonce()).example", path: "/secret")
        case ("public.example", "/hop-public"): redirect(toHost: "public-\(Self.nextNonce()).example", path: "/fine")
        case (_, "/fine") where host.hasPrefix("public-"): respond(200, "OK")
        case (_, "/secret") where host.hasPrefix("private-"): respond(200, "SECRET")
        default: respond(404, "?")
        }
    }
}

/// The DNS the tests play: `private-*.example` lives in RFC 1918 space,
/// everything else is public — and every lookup tells `StubTransport` the
/// gate has reached its decision for that host (see `gateConsulted`). Answers
/// without suspending, so the gate's decision completes on the calling thread.
private struct SignallingDNS: HostResolving {
    func addresses(for host: String) async -> [String]? {
        let answer = host.hasPrefix("private-") ? ["10.0.0.1"] : ["93.184.216.34"]
        StubTransport.gateConsulted(host)
        return answer
    }
}

struct HTTPFetchingTests {
    private func fetcher() -> URLSessionHTTPFetcher {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubTransport.self]
        return URLSessionHTTPFetcher(timeout: 5, resolver: SignallingDNS(), configuration: configuration)
    }

    @Test("a redirect into private space is NOT followed — the 302 is the final response")
    func privateRedirectRefused() async throws {
        let (data, response) = try await fetcher().fetch(URLRequest(url: #require(URL(string: "https://public.example/hop"))))
        #expect(response.statusCode == 302)
        #expect(String(decoding: data, as: UTF8.self) != "SECRET")
    }

    @Test("a redirect to a public host is followed as before")
    func publicRedirectFollowed() async throws {
        let (data, response) = try await fetcher().fetch(URLRequest(url: #require(URL(string: "https://public.example/hop-public"))))
        #expect(response.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == "OK")
    }
}

struct RefusedRedirectToolTests {
    private func fetcher() -> URLSessionHTTPFetcher {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubTransport.self]
        return URLSessionHTTPFetcher(timeout: 5, resolver: SignallingDNS(), configuration: configuration)
    }

    @Test("3xx is its own class — a refused hop must not read as a page")
    func classifierKnowsRedirects() {
        #expect(HTTPStatus.classify(301) == .redirect)
        #expect(HTTPStatus.classify(302) == .redirect)
        #expect(HTTPStatus.classify(307) == .redirect)
        #expect(HTTPStatus.classify(200) == .ok)
    }

    @Test("fetch_page reports a refused redirect as an HTTP error, never as the stub's text (#266 review 3)")
    func fetchPageReportsRefusedRedirect() async throws {
        let tool = FetchPageTool(fetcher: fetcher(), resolver: SignallingDNS())
        let result = try await tool.execute(input: ["url": "https://public.example/hop"])
        #expect(result.output.hasPrefix("Error: the page returned HTTP 302"))
        #expect(!result.output.contains("redirecting"))
        #expect(await tool.readablePage(at: "https://public.example/hop") == nil)
    }

    @Test("open_link's brief carries the refused hop as a failure, not as page text")
    func openLinkBriefReportsRefusedRedirect() async throws {
        let tool = OpenLinkTool(fetcher: fetcher(), resolver: SignallingDNS()) { _ in }
        let result = try await tool.execute(input: ["url": "https://public.example/hop"])
        #expect(result.output.contains("HTTP 302"))
        #expect(!result.output.contains("redirecting"))
    }
}

struct RedirectPolicyTests {
    private struct Table: HostResolving {
        let table: [String: [String]]
        func addresses(for host: String) async -> [String]? {
            host == "down.example" ? nil : (table[host] ?? []) // down.example: the lookup FAILS
        }
    }

    @Test("follow: public http(s) yes; private literal, private-resolving name, failed lookup, other schemes no")
    func decisions() async throws {
        let dns = Table(table: ["ok.example": ["93.184.216.34"], "lan.example": ["192.168.1.7"]])
        #expect(try await RedirectPolicy.follow(URLRequest(url: #require(URL(string: "https://ok.example/a"))), resolver: dns) != nil)
        #expect(try await RedirectPolicy.follow(URLRequest(url: #require(URL(string: "http://127.0.0.1/a"))), resolver: dns) == nil)
        #expect(try await RedirectPolicy.follow(URLRequest(url: #require(URL(string: "https://lan.example/a"))), resolver: dns) == nil)
        #expect(try await RedirectPolicy.follow(URLRequest(url: #require(URL(string: "https://down.example/a"))), resolver: dns) == nil)
        #expect(try await RedirectPolicy.follow(URLRequest(url: #require(URL(string: "file:///etc/hosts"))), resolver: dns) == nil)
        #expect(try await RedirectPolicy.follow(URLRequest(url: #require(URL(string: "ftp://ok.example/a"))), resolver: dns) == nil)
    }
}
