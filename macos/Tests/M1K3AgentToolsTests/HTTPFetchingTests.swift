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
//

import Foundation
@testable import M1K3AgentTools
import M1K3Preview
import Testing

/// Scripted servers: public.example/hop → 302 to a private literal;
/// public.example/hop-public → 302 to public.example/fine; /fine → 200 OK;
/// 10.0.0.1/secret → 200 SECRET (must never be reached through a redirect).
private final class StubTransport: URLProtocol {
    /// How long a 302 waits for the gate's decision before it is delivered as
    /// the final response. The gate decides asynchronously (an async delegate
    /// plus a resolver hop); a followed hop stops this load in well under
    /// 100 ms even on a loaded CI runner, so this is 5× the observed worst case.
    static let decisionGrace: DispatchTimeInterval = .milliseconds(500)

    /// Flipped by `stopLoading` (a followed hop) OR by the grace timer the
    /// moment it commits to delivering the 302 — whichever wins, the other
    /// becomes a no-op. No lock is ever held across a client callback.
    private let lock = NSLock()
    private var stopped = false

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func stopLoading() {
        lock.withLock { stopped = true }
    }

    override func startLoading() {
        guard let url = request.url, let client else { return }
        func respond(_ status: Int, _ body: String, headers: [String: String] = [:]) {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: Data(body.utf8))
            client.urlProtocolDidFinishLoading(self)
        }
        func redirect(to target: String) {
            let response = HTTPURLResponse(
                url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target]
            )!
            client.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: target)!), redirectResponse: response)
            // If the session declines the hop, this 302 is the final answer —
            // but only once the gate has DECIDED. Delivering it straight away
            // raced the async decision: when the decision landed after the
            // body, URLSession neither followed nor finished, and the task hung
            // to its timeout (-1001 in three of four CI runs, 2026-09-11). A
            // followed hop calls `stopLoading` on this load; a declined one
            // leaves it running, so the body is delivered after the grace only
            // if the session is still listening.
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.decisionGrace) { [self] in
                // Check and commit in one locked step: a `stopLoading` landing
                // after this is a no-op, so a stale 302 can never reach a load
                // the session already abandoned (both passes on #291).
                let shouldDeliver = lock.withLock { () -> Bool in
                    guard !stopped else { return false }
                    stopped = true
                    return true
                }
                guard shouldDeliver else { return }
                client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client.urlProtocol(self, didLoad: Data("redirecting".utf8))
                client.urlProtocolDidFinishLoading(self)
            }
        }
        switch (url.host, url.path) {
        case ("public.example", "/hop"): redirect(to: "http://10.0.0.1/secret")
        case ("public.example", "/hop-public"): redirect(to: "https://public.example/fine")
        case ("public.example", "/fine"): respond(200, "OK")
        case ("10.0.0.1", _): respond(200, "SECRET")
        default: respond(404, "?")
        }
    }
}

private struct PublicOnlyDNS: HostResolving {
    func addresses(for _: String) async -> [String]? {
        ["93.184.216.34"]
    }
}

struct HTTPFetchingTests {
    private func fetcher() -> URLSessionHTTPFetcher {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubTransport.self]
        return URLSessionHTTPFetcher(timeout: 5, resolver: PublicOnlyDNS(), configuration: configuration)
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
        return URLSessionHTTPFetcher(timeout: 5, resolver: PublicOnlyDNS(), configuration: configuration)
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
        let tool = FetchPageTool(fetcher: fetcher(), resolver: PublicOnlyDNS())
        let result = try await tool.execute(input: ["url": "https://public.example/hop"])
        #expect(result.output.hasPrefix("Error: the page returned HTTP 302"))
        #expect(!result.output.contains("redirecting"))
        #expect(await tool.readablePage(at: "https://public.example/hop") == nil)
    }

    @Test("open_link's brief carries the refused hop as a failure, not as page text")
    func openLinkBriefReportsRefusedRedirect() async throws {
        let tool = OpenLinkTool(fetcher: fetcher(), resolver: PublicOnlyDNS()) { _ in }
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
