//
//  JSONRPCIDRemapTests.swift
//  M1K3MCPKitTests
//
//  Contract for the JSON-RPC id remap that isolates the shared stateless
//  transport's response routing from client id collisions (the #176 DoS).
//
//  Signed: Kev + claude-opus-4-8, 2026-09-01, Confidence 0.95. Prior: none.
//

import Foundation
@testable import M1K3MCPKit
import MCP
import Testing

private func body(_ json: String) -> Data {
    Data(json.utf8)
}

struct JSONRPCIDRemapTests {
    @Test("reads an integer id")
    func readsIntID() {
        #expect(HTTPWireCodec.requestID(inBody: body(#"{"jsonrpc":"2.0","id":1,"method":"tools/call"}"#)) == .int(1))
    }

    @Test("reads a string id")
    func readsStringID() {
        #expect(HTTPWireCodec.requestID(inBody: body(#"{"jsonrpc":"2.0","id":"abc","method":"x"}"#)) == .string("abc"))
    }

    @Test("a notification (no id) reads back nil — nothing to isolate")
    func notificationHasNoID() {
        #expect(HTTPWireCodec.requestID(inBody: body(#"{"jsonrpc":"2.0","method":"notify"}"#)) == nil)
    }

    @Test("an explicit id:null is a REQUEST id (.null), remapped like any other — not a notification")
    func explicitNullID() throws {
        #expect(HTTPWireCodec.requestID(inBody: body(#"{"jsonrpc":"2.0","id":null,"method":"x"}"#)) == .null)
        let nullBody = body(#"{"jsonrpc":"2.0","id":null,"method":"x"}"#)
        let rewritten = try #require(HTTPWireCodec.replacingID(inBody: nullBody, with: .string("m1k3#7")))
        #expect(HTTPWireCodec.requestID(inBody: rewritten) == .string("m1k3#7"))
        // and a server response addressed to m1k3#7 maps back to null
        let resp = HTTPResponse.data(body(#"{"jsonrpc":"2.0","id":"m1k3#7","result":{}}"#))
        guard case let .data(d, _) = HTTPWireCodec.replacingResponseID(resp, with: .null) else {
            Issue.record("expected .data"); return
        }
        #expect(HTTPWireCodec.requestID(inBody: d) == .null)
    }

    @Test("junk / non-object bodies read back nil")
    func junkHasNoID() {
        #expect(HTTPWireCodec.requestID(inBody: body("not json")) == nil)
        #expect(HTTPWireCodec.requestID(inBody: body("[1,2,3]")) == nil)
    }

    @Test("replacing the id round-trips and preserves method + params")
    func replaceRoundTrips() throws {
        let original = body(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search_knowledge"}}"#)
        let rewritten = try #require(HTTPWireCodec.replacingID(inBody: original, with: .string("m1k3#42")))
        #expect(HTTPWireCodec.requestID(inBody: rewritten) == .string("m1k3#42"))
        let obj = try #require(try JSONSerialization.jsonObject(with: rewritten) as? [String: Any])
        #expect(obj["method"] as? String == "tools/call")
        let params = try #require(obj["params"] as? [String: Any])
        #expect(params["name"] as? String == "search_knowledge")
    }

    @Test("replacing on a body with no id returns nil (leave it untouched)")
    func replaceOnNoIDReturnsNil() {
        #expect(HTTPWireCodec.replacingID(inBody: body(#"{"jsonrpc":"2.0","method":"notify"}"#), with: .int(9)) == nil)
    }

    @Test("a .data response has its id mapped back to the client's original")
    func mapsResponseIDBack() {
        let serverResponse = HTTPResponse.data(body(#"{"jsonrpc":"2.0","id":"m1k3#42","result":{"ok":true}}"#))
        let mapped = HTTPWireCodec.replacingResponseID(serverResponse, with: .int(1))
        guard case let .data(d, _) = mapped else { Issue.record("expected .data"); return }
        #expect(HTTPWireCodec.requestID(inBody: d) == .int(1))
    }

    @Test("non-.data responses pass through unchanged")
    func nonDataPassesThrough() {
        let accepted = HTTPResponse.accepted()
        if case .accepted = HTTPWireCodec.replacingResponseID(accepted, with: .int(1)) {} else {
            Issue.record("accepted should pass through")
        }
    }
}

/// The shared isolate/restore seam BOTH the loopback server and the LAN
/// Brain-at-Home route apply (the LAN route had missed it — #176 was still live
/// there). Pinning it here covers both surfaces with one contract.
struct MCPRequestIDRemapTests {
    private func request(_ json: String) -> HTTPRequest {
        HTTPRequest(method: "POST", headers: [:], body: body(json), path: "/mcp")
    }

    @Test("isolate rewrites the request id and restore maps the response back")
    func isolateAndRestore() throws {
        let isolated = try #require(
            MCPRequestIDRemap.isolate(
                request(#"{"jsonrpc":"2.0","id":1,"method":"tools/call"}"#), as: .string("m1k3-lan#5")
            )
        )
        #expect(isolated.clientID == .int(1))
        #expect(try HTTPWireCodec.requestID(inBody: #require(isolated.request.body)) == .string("m1k3-lan#5"))

        let serverResponse = HTTPResponse.data(body(#"{"jsonrpc":"2.0","id":"m1k3-lan#5","result":{}}"#))
        guard case let .data(mapped, _) = MCPRequestIDRemap.restore(serverResponse, to: isolated.clientID) else {
            Issue.record("expected .data"); return
        }
        #expect(HTTPWireCodec.requestID(inBody: mapped) == .int(1))
    }

    @Test("a notification (no id) passes through untouched with nothing to restore")
    func notificationPassesThrough() throws {
        let original = request(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        let isolated = try #require(MCPRequestIDRemap.isolate(original, as: .string("m1k3#1")))
        #expect(isolated.clientID == nil)
        #expect(isolated.request.body == original.body)
        let accepted = HTTPResponse.accepted()
        if case .accepted = MCPRequestIDRemap.restore(accepted, to: isolated.clientID) {} else {
            Issue.record("restore with a nil clientID must pass through")
        }
    }

    @Test("an explicit id:null is isolated like any other id")
    func nullIDIsolated() throws {
        let isolated = try #require(
            MCPRequestIDRemap.isolate(request(#"{"jsonrpc":"2.0","id":null,"method":"x"}"#), as: .string("m1k3#9"))
        )
        #expect(isolated.clientID == .null)
        #expect(try HTTPWireCodec.requestID(inBody: #require(isolated.request.body)) == .string("m1k3#9"))
    }
}
