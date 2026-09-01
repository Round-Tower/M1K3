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
