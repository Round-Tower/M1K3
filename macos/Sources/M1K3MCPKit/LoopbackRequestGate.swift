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
//  listener, a present Origin must be a loopback page, and the body must be
//  declared JSON. Everything else is refused with the status the SDK would
//  have used, and the live session never notices.
//
//  Pure — the listener wiring is pinned in LocalMCPHTTPServerTests. The SDK's
//  OriginValidator.localhost() stays in the transport as a second belt.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-11, Confidence 0.9 (every row of
//  the table pinned in LoopbackRequestGateTests; the DNS-rebinding shape is
//  the MCP spec's own worked example). Prior: Unknown.
//

import Foundation
import MCP

public enum LoopbackRequestGate {
    public enum Refusal: Equatable, Sendable, CustomStringConvertible {
        case wrongPath(String)
        case missingHost
        case foreignHost(String)
        case portMismatch(String)
        case foreignOrigin(String)
        case unsupportedMediaType(String?)

        public var statusCode: Int {
            switch self {
            case .wrongPath: 404
            case .missingHost: 400
            case .foreignHost, .portMismatch, .foreignOrigin: 403
            case .unsupportedMediaType: 415
            }
        }

        public var description: String {
            switch self {
            case let .wrongPath(path): "Not Found: \(path) is not the MCP endpoint (/mcp)"
            case .missingHost: "Bad Request: Host header required"
            case let .foreignHost(host): "Forbidden: Host \(host) is not this loopback listener"
            case let .portMismatch(host): "Forbidden: Host \(host) names another port"
            case let .foreignOrigin(origin): "Forbidden: Origin \(origin) is not a loopback page"
            case let .unsupportedMediaType(type):
                "Unsupported Media Type: Content-Type must be application/json (got \(type ?? "none"))"
            }
        }
    }

    public static let endpointPath = "/mcp"

    /// Nil admits the request. Judged in order: path, Host, Origin, Content-Type
    /// — so a forged Host is always reported as a Host problem.
    public static func refusal(for request: HTTPRequest, boundPort: UInt16) -> Refusal? {
        let path = request.path ?? ""
        if path != endpointPath { return .wrongPath(path) }

        guard let host = request.header("Host")?.trimmingCharacters(in: .whitespaces), !host.isEmpty else {
            return .missingHost
        }
        let (hostName, hostPort) = splitHostPort(host)
        guard isLoopbackName(hostName) else { return .foreignHost(host) }
        if let hostPort, hostPort != boundPort { return .portMismatch(host) }

        if let origin = request.header("Origin")?.trimmingCharacters(in: .whitespaces) {
            guard let url = URL(string: origin), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let originHost = url.host, isLoopbackName(originHost)
            else { return .foreignOrigin(origin) }
        }

        let contentType = request.header("Content-Type")
        guard let contentType, isJSON(contentType) else { return .unsupportedMediaType(contentType) }
        return nil
    }

    // MARK: - Pieces

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

    /// `host[:port]` with the bracketed IPv6 form kept whole. A port that is
    /// not a number is reported as no port, which fails the name check anyway.
    static func splitHostPort(_ value: String) -> (name: String, port: UInt16?) {
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return (value, nil) }
            let name = String(value[...close])
            let rest = value[value.index(after: close)...]
            guard rest.hasPrefix(":") else { return (name, nil) }
            return (name, UInt16(rest.dropFirst()))
        }
        guard let colon = value.lastIndex(of: ":") else { return (value, nil) }
        return (String(value[..<colon]), UInt16(value[value.index(after: colon)...]))
    }

    /// `application/json` with any parameters (`; charset=utf-8`), case-insensitive.
    static func isJSON(_ contentType: String) -> Bool {
        let media = contentType.split(separator: ";", maxSplits: 1).first.map(String.init) ?? contentType
        return media.trimmingCharacters(in: .whitespaces).lowercased() == "application/json"
    }
}
