//
//  HTTPFetching.swift
//  M1K3AgentTools
//
//  The network seam behind WebSearchTool — tools test against a scripted
//  fake; only this adapter touches URLSession. Tight timeout so a stalled
//  search can't hang the agent loop.
//
//  Signed: Kev + claude-fable-5, 2026-06-09, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-09-10, Confidence 0.85 — #210 / #266 review: the live
//  fetcher owns a `RedirectGate` delegate, so a 3xx to a local / private / unresolvable host is
//  NOT followed (the 3xx comes back as the final response and the tool reports it). One choke
//  point for fetch_page, open_link, the search deepen and the MCP open_link — the resolve-before-
//  fetch gate judged only the URL the model asked for; a public site's redirect walked past it.
//  Production shares ONE gated session (a URLSession with a delegate lives until invalidated).

import Foundation
import M1K3Preview

public protocol HTTPFetching: Sendable {
    func fetch(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse)
}

public struct URLSessionHTTPFetcher: HTTPFetching {
    private let timeout: TimeInterval
    private let session: URLSession

    /// The one production session: gated redirects, system resolver.
    private static let gatedShared = URLSession(
        configuration: .default, delegate: RedirectGate(resolver: SystemHostResolver()), delegateQueue: nil
    )

    public init(timeout: TimeInterval = 12) {
        self.timeout = timeout
        session = Self.gatedShared
    }

    /// A dedicated session — tests stub the transport through `configuration`
    /// (`protocolClasses`) and pin the gate with a fake resolver.
    init(timeout: TimeInterval, resolver: any HostResolving, configuration: URLSessionConfiguration) {
        self.timeout = timeout
        session = URLSession(configuration: configuration, delegate: RedirectGate(resolver: resolver), delegateQueue: nil)
    }

    public func fetch(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        var timed = request
        timed.timeoutInterval = timeout
        let (data, response) = try await session.data(for: timed)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

/// Where a redirect may go: http(s) only, and the target host passes the same
/// resolved gate the original URL did. nil = do not follow (the 3xx is the
/// final response). Pure over the resolver seam, so the decision is pinned
/// without a network.
public enum RedirectPolicy {
    public static func follow(_ request: URLRequest, resolver: any HostResolving) async -> URLRequest? {
        guard let url = request.url, let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme)
        else { return nil }
        guard await !WebURLPolicy.isLocalOrPrivate(url, resolver: resolver) else { return nil }
        return request
    }
}

/// The session delegate that applies `RedirectPolicy` on every hop.
final class RedirectGate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let resolver: any HostResolving

    init(resolver: any HostResolving) {
        self.resolver = resolver
    }

    func urlSession(
        _: URLSession, task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        await RedirectPolicy.follow(request, resolver: resolver)
    }
}
