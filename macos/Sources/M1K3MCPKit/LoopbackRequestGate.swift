//
//  LoopbackRequestGate.swift
//  M1K3MCPKit
//
//  The door on the in-app MCP listener. Every request is judged here BEFORE
//  the initialize sniff in LocalMCPHTTPServer, because that sniff has side
//  effects — it tears down the live session and stamps the visitor's name —
//  and the SDK transport's own validators only run after it.
//
//  What a forged request looks like: a browser page whose hostname was
//  rebound to 127.0.0.1 (same-origin, so CORS never applies) sends
//  `Host: attacker.example:4242`; a cross-site page sends a "simple" POST with
//  `Content-Type: text/plain` that needs no preflight. Either used to reach
//  the sniff. Now: the path must be /mcp, Host must name THIS loopback
//  listener (one Host, well-formed port), a present Origin must be a loopback
//  page, and a POST body must be declared JSON. Everything else is refused
//  with a plain status (404 / 400 / 403 / 415 — the SDK's own belt says 421
//  for a bad Host; we don't mirror that number) and the live session never
//  notices. Residual, by design: a request that passes this door but fails
//  the transport's Accept / protocol-version checks still reaches the sniff —
//  not a browser-reachable shape.
//
//  Pure — the listener wiring is pinned in LocalMCPHTTPServerTests. The SDK's
//  OriginValidator.localhost() stays in the transport as a second belt.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-10, Confidence 0.9 (every row of
//  the table pinned in LoopbackRequestGateTests; the DNS-rebinding shape is
//  the MCP spec's own worked example). Prior: Unknown.
//

import Foundation
import MCP

public enum LoopbackRequestGate {
    public enum Refusal: Equatable, Sendable, CustomStringConvertible {
        case wrongPath(String)
        case missingHost
        case ambiguousHost
        case foreignHost(String)
        case portMismatch(String)
        case foreignOrigin(String)
        case unsupportedMediaType(String?)

        public var statusCode: Int {
            switch self {
            case .wrongPath: 404
            case .missingHost, .ambiguousHost: 400
            case .foreignHost, .portMismatch, .foreignOrigin: 403
            case .unsupportedMediaType: 415
            }
        }

        public var description: String {
            switch self {
            case let .wrongPath(path): "Not Found: \(Self.clip(path)) is not the MCP endpoint (/mcp)"
            case .missingHost: "Bad Request: Host header required"
            case .ambiguousHost: "Bad Request: more than one Host header"
            case let .foreignHost(host): "Forbidden: Host \(Self.clip(host)) is not this loopback listener"
            case let .portMismatch(host): "Forbidden: Host \(Self.clip(host)) names another port"
            case let .foreignOrigin(origin): "Forbidden: Origin \(Self.clip(origin)) is not a loopback page"
            case let .unsupportedMediaType(type):
                "Unsupported Media Type: Content-Type must be application/json (got \(Self.clip(type ?? "none")))"
            }
        }

        /// Attacker-supplied text goes back in the body and into the log —
        /// never more than a glance of it.
        static func clip(_ value: String, to limit: Int = 64) -> String {
            value.count <= limit ? value : String(value.prefix(limit)) + "…"
        }
    }

    public static let endpointPath = "/mcp"

    /// Nil admits the request. Judged in order: path, Host, Origin, Content-Type
    /// — so a forged Host is always reported as a Host problem. The JSON rule
    /// applies to POST only; the transport answers other methods with 405.
    /// `duplicateHeaders` is the codec's report of header names sent more than
    /// once (lowercased): the dictionary the SDK hands us keeps only the last
    /// value, so two Host lines are refused on the report, never judged on the
    /// survivor (RFC 9112 §3.2).
    public static func refusal(
        for request: HTTPRequest, boundPort: UInt16, duplicateHeaders: [String] = []
    ) -> Refusal? {
        let path = normalisedPath(request.path ?? "")
        if path != endpointPath { return .wrongPath(request.path ?? "") }

        let hosts = values(of: "Host", in: request)
        guard let host = hosts.first, !host.isEmpty else { return .missingHost }
        if Set(hosts).count > 1 || duplicateHeaders.contains("host") { return .ambiguousHost }
        let (hostName, hostPort) = splitHostPort(host)
        guard isLoopbackName(hostName) else { return .foreignHost(host) }
        switch hostPort {
        case .none: break
        case let .some(.some(port)) where port == boundPort: break
        default: return .portMismatch(host) // another port, or a segment that is not a port
        }

        let origins = values(of: "Origin", in: request)
        if let origin = origins.first {
            guard Set(origins).count == 1, !duplicateHeaders.contains("origin"),
                  let url = URL(string: origin), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let originHost = url.host, isLoopbackName(originHost)
            else { return .foreignOrigin(origin) }
        }

        if request.method.uppercased() == "POST" {
            let contentType = request.header("Content-Type")
            guard let contentType, isJSON(contentType) else { return .unsupportedMediaType(contentType) }
        }
        return nil
    }

    // MARK: - Pieces

    /// Every value sent under a header name, case-insensitively. Differently
    /// cased duplicates survive the codec as separate keys; same-cased ones
    /// arrive through `duplicateHeaders` instead.
    static func values(of name: String, in request: HTTPRequest) -> [String] {
        let wanted = name.lowercased()
        return request.headers
            .filter { $0.key.lowercased() == wanted }
            .map { $0.value.trimmingCharacters(in: .whitespaces) }
            .sorted()
    }

    /// The request-target without query or fragment, one trailing slash
    /// dropped, and the absolute form (`POST http://127.0.0.1:4242/mcp`) a
    /// proxy-configured client emits reduced to its path. Only a LEADING
    /// scheme counts — a `://` inside a query value is part of the query.
    static func normalisedPath(_ target: String) -> String {
        var path = target
        let lowered = path.lowercased()
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            let authorityStart = path.index(path.startIndex, offsetBy: lowered.hasPrefix("https://") ? 8 : 7)
            let afterAuthority = path[authorityStart...].firstIndex(of: "/")
            path = afterAuthority.map { String(path[$0...]) } ?? "/"
        }
        if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) { path = String(path[..<cut]) }
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// `127.0.0.1`, `localhost` (trailing dot tolerated), `::1` bare or
    /// bracketed — case-insensitive. Nothing else, not even 127.0.0.2: the
    /// listener binds exactly one address.
    static func isLoopbackName(_ name: String) -> Bool {
        var lowered = name.lowercased()
        if lowered.hasSuffix(".") { lowered.removeLast() }
        if lowered.hasPrefix("["), lowered.hasSuffix("]") {
            lowered = String(lowered.dropFirst().dropLast())
        }
        return lowered == "127.0.0.1" || lowered == "localhost" || lowered == "::1"
    }

    /// `host[:port]` with the bracketed IPv6 form kept whole. Outer nil = no
    /// port segment; inner nil = a segment that is not a port (`:99999`,
    /// `:4242@evil`) — the caller refuses that rather than reading it as none.
    static func splitHostPort(_ value: String) -> (name: String, port: UInt16??) {
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return (value, nil) }
            let name = String(value[...close])
            let rest = value[value.index(after: close)...]
            guard rest.hasPrefix(":") else { return (name, rest.isEmpty ? nil : .some(nil)) }
            return (name, .some(UInt16(rest.dropFirst())))
        }
        guard let colon = value.lastIndex(of: ":") else { return (value, nil) }
        return (String(value[..<colon]), .some(UInt16(value[value.index(after: colon)...])))
    }

    /// `application/json` with any parameters (`; charset=utf-8`), case-insensitive.
    static func isJSON(_ contentType: String) -> Bool {
        let media = contentType.split(separator: ";", maxSplits: 1).first.map(String.init) ?? contentType
        return media.trimmingCharacters(in: .whitespaces).lowercased() == "application/json"
    }
}
