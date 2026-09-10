//
//  LoopbackRequestGateTests.swift
//  M1K3MCPKitTests
//
//  The gate every request to the in-app MCP listener passes BEFORE the
//  initialize sniff: a request whose Host is not this loopback listener, or
//  whose Origin is a browser page from anywhere but loopback, is refused. This
//  is the DNS-rebinding defence the MCP spec requires — and the reason the
//  session-rebuild sniff can no longer be reached by a forged request.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-11, Confidence 0.9 (pure table,
//  every row pinned; the listener wiring is pinned in LocalMCPHTTPServerTests).
//  Prior: Unknown.
//

import Foundation
@testable import M1K3MCPKit
import MCP
import Testing

private func request(
    host: String? = "127.0.0.1:4242", origin: String? = nil, lowercase: Bool = false,
    contentType: String? = "application/json", path: String = "/mcp"
) -> HTTPRequest {
    var headers: [String: String] = [:]
    if let host { headers[lowercase ? "host" : "Host"] = host }
    if let origin { headers[lowercase ? "origin" : "Origin"] = origin }
    if let contentType { headers[lowercase ? "content-type" : "Content-Type"] = contentType }
    return HTTPRequest(method: "POST", headers: headers, body: Data("{}".utf8), path: path)
}

struct LoopbackRequestGateTests {
    @Test("every loopback spelling of Host is admitted, with or without the bound port")
    func admitsLoopbackHosts() {
        for host in ["127.0.0.1:4242", "localhost:4242", "[::1]:4242", "localhost", "127.0.0.1", "LOCALHOST:4242", "localhost.:4242"] {
            #expect(LoopbackRequestGate.refusal(for: request(host: host), boundPort: 4242) == nil, "\(host)")
        }
    }

    @Test("header names are matched case-insensitively (HTTP/2-style clients lowercase them)")
    func admitsLowercaseHeaderNames() {
        #expect(LoopbackRequestGate.refusal(for: request(host: "127.0.0.1:4242", lowercase: true), boundPort: 4242) == nil)
        #expect(LoopbackRequestGate.refusal(for: request(origin: "https://evil.example", lowercase: true), boundPort: 4242) == .foreignOrigin("https://evil.example"))
    }

    @Test("a rebound hostname pointing at 127.0.0.1 is refused by name")
    func refusesForeignHost() {
        #expect(LoopbackRequestGate.refusal(for: request(host: "attacker.example:4242"), boundPort: 4242) == .foreignHost("attacker.example:4242"))
        #expect(LoopbackRequestGate.refusal(for: request(host: "127.0.0.1.attacker.example:4242"), boundPort: 4242) == .foreignHost("127.0.0.1.attacker.example:4242"))
    }

    @Test("a loopback Host naming another port is refused")
    func refusesPortMismatch() {
        #expect(LoopbackRequestGate.refusal(for: request(host: "127.0.0.1:9999"), boundPort: 4242) == .portMismatch("127.0.0.1:9999"))
    }

    @Test("HTTP/1.1 requires Host — a request without one is refused")
    func refusesMissingHost() {
        #expect(LoopbackRequestGate.refusal(for: request(host: nil), boundPort: 4242) == .missingHost)
    }

    @Test("no Origin (curl, claude, codex) is admitted; a loopback page origin on any port is admitted")
    func admitsAbsentAndLoopbackOrigins() {
        #expect(LoopbackRequestGate.refusal(for: request(origin: nil), boundPort: 4242) == nil)
        for origin in ["http://localhost:3000", "http://127.0.0.1:5173", "https://[::1]:8443", "http://localhost"] {
            #expect(LoopbackRequestGate.refusal(for: request(origin: origin), boundPort: 4242) == nil, Comment(rawValue: origin))
        }
    }

    @Test("a browser page from anywhere else — including a rebound name and the opaque 'null' — is refused")
    func refusesForeignOrigins() {
        for origin in ["https://evil.example", "http://attacker.example:4242", "null", "file://"] {
            #expect(LoopbackRequestGate.refusal(for: request(origin: origin), boundPort: 4242) == .foreignOrigin(origin), Comment(rawValue: origin))
        }
    }

    @Test("the body must be declared JSON — a browser's no-preflight 'simple' POST is refused")
    func refusesNonJSONBodies() {
        #expect(LoopbackRequestGate.refusal(for: request(contentType: "text/plain"), boundPort: 4242) == .unsupportedMediaType("text/plain"))
        #expect(LoopbackRequestGate.refusal(for: request(contentType: nil), boundPort: 4242) == .unsupportedMediaType(nil))
        #expect(LoopbackRequestGate.refusal(for: request(contentType: "application/json; charset=utf-8"), boundPort: 4242) == nil)
        #expect(LoopbackRequestGate.refusal(for: request(contentType: "Application/JSON"), boundPort: 4242) == nil)
    }

    @Test("only /mcp is served")
    func refusesOtherPaths() {
        #expect(LoopbackRequestGate.refusal(for: request(path: "/"), boundPort: 4242) == .wrongPath("/"))
        #expect(LoopbackRequestGate.refusal(for: request(path: "/mcp/../admin"), boundPort: 4242) == .wrongPath("/mcp/../admin"))
    }

    @Test("each refusal carries the status the SDK would have answered with")
    func statusCodes() {
        #expect(LoopbackRequestGate.Refusal.wrongPath("/").statusCode == 404)
        #expect(LoopbackRequestGate.Refusal.missingHost.statusCode == 400)
        #expect(LoopbackRequestGate.Refusal.foreignHost("x").statusCode == 403)
        #expect(LoopbackRequestGate.Refusal.foreignOrigin("x").statusCode == 403)
        #expect(LoopbackRequestGate.Refusal.unsupportedMediaType(nil).statusCode == 415)
    }

    @Test("Host is judged before Origin, so a forged Host never reads as an Origin problem")
    func hostIsJudgedFirst() {
        #expect(LoopbackRequestGate.refusal(for: request(host: "attacker.example", origin: "https://evil.example"), boundPort: 4242) == .foreignHost("attacker.example"))
    }
}
