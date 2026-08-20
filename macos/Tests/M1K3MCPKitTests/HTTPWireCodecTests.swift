//
//  HTTPWireCodecTests.swift
//  M1K3MCPKitTests
//
//  The pure HTTP/1.1 wire layer under LocalMCPHTTPServer — parse, encode, and
//  the initialize sniff are all unit-tested here; the NWListener socket shell
//  stays thin and is verified live.
//

import Foundation
@testable import M1K3MCPKit
import MCP
import Testing

private func bytes(_ string: String) -> Data {
    Data(string.utf8)
}

struct HTTPWireCodecTests {
    // MARK: - parseRequest

    @Test("a complete POST parses into method, path, headers, and body")
    func parseCompletePost() throws {
        let body = #"{"jsonrpc":"2.0","method":"ping","id":1}"#
        let raw = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:4242\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let parsed = try #require(HTTPWireCodec.parseRequest(bytes(raw)))
        #expect(parsed.request.method == "POST")
        #expect(parsed.request.path == "/mcp")
        #expect(parsed.request.header("content-type") == "application/json")
        #expect(parsed.request.body == bytes(body))
        #expect(parsed.consumed == raw.utf8.count)
    }

    @Test("an incomplete head returns nil — keep accumulating")
    func parseIncompleteHead() {
        #expect(HTTPWireCodec.parseRequest(bytes("POST /mcp HTTP/1.1\r\nHost: x")) == nil)
    }

    @Test("a head with a partial body returns nil until Content-Length bytes arrive")
    func parsePartialBody() {
        let raw = "POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n\r\n12345"
        #expect(HTTPWireCodec.parseRequest(bytes(raw)) == nil)
    }

    @Test("a GET without Content-Length parses with no body")
    func parseGetNoBody() throws {
        let raw = "GET /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        let parsed = try #require(HTTPWireCodec.parseRequest(bytes(raw)))
        #expect(parsed.request.method == "GET")
        #expect(parsed.request.body == nil || parsed.request.body?.isEmpty == true)
    }

    @Test("header names are surfaced case-insensitively via header(_:)")
    func headerCaseInsensitive() throws {
        let raw = "POST / HTTP/1.1\r\ncOnTeNt-LeNgTh: 0\r\nAccept: application/json\r\n\r\n"
        let parsed = try #require(HTTPWireCodec.parseRequest(bytes(raw)))
        #expect(parsed.request.header("Accept") == "application/json")
    }

    // MARK: - clientName

    @Test("clientName reads params.clientInfo.name off an initialize body")
    func clientNameFromInitialize() {
        let body = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":"#
            + #"{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"2.0"}}}"#
        #expect(HTTPWireCodec.clientName(fromInitializeBody: bytes(body)) == "claude-code")
    }

    @Test("clientName is nil for a missing/blank name, junk JSON, or a non-initialize body")
    func clientNameAbsent() {
        let noInfo = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}"#
        let blank = #"{"method":"initialize","params":{"clientInfo":{"name":"  "}}}"#
        let notInitialize = #"{"jsonrpc":"2.0","method":"ping","id":1}"#
        #expect(HTTPWireCodec.clientName(fromInitializeBody: bytes(noInfo)) == nil)
        #expect(HTTPWireCodec.clientName(fromInitializeBody: bytes(blank)) == nil)
        #expect(HTTPWireCodec.clientName(fromInitializeBody: bytes(notInitialize)) == nil)
        #expect(HTTPWireCodec.clientName(fromInitializeBody: bytes("not json")) == nil)
    }

    // MARK: - encode

    @Test("a data response encodes status line, headers, content-length, and body")
    func encodeData() {
        let payload = bytes(#"{"ok":true}"#)
        let encoded = HTTPWireCodec.encode(.data(payload, headers: ["Content-Type": "application/json"]))
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Content-Type: application/json\r\n"))
        #expect(text.contains("Content-Length: \(payload.count)\r\n"))
        #expect(text.contains("Connection: close\r\n"))
        #expect(text.hasSuffix("\r\n\r\n" + #"{"ok":true}"#))
    }

    @Test("an accepted response encodes 202 with zero content length")
    func encodeAccepted() {
        let text = String(decoding: HTTPWireCodec.encode(.accepted()), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 202 Accepted\r\n"))
        #expect(text.contains("Content-Length: 0\r\n"))
    }

    @Test("an error response carries the JSON-RPC error body and its status")
    func encodeError() {
        let response = MCP.HTTPResponse.error(statusCode: 405, MCPError.invalidRequest("nope"))
        let text = String(decoding: HTTPWireCodec.encode(response), as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 405 "))
        #expect(text.contains("jsonrpc"))
    }

    // MARK: - initialize sniff

    @Test("an initialize request is detected regardless of key order and whitespace")
    func sniffInitialize() {
        #expect(HTTPWireCodec.isInitializeRequest(
            body: bytes(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{}}"#)
        ))
        #expect(HTTPWireCodec.isInitializeRequest(
            body: bytes(#"{ "method" : "initialize", "id": 0 }"#)
        ))
    }

    @Test("non-initialize methods and junk are not initialize")
    func sniffOthers() {
        #expect(!HTTPWireCodec.isInitializeRequest(body: bytes(#"{"method":"tools/call"}"#)))
        #expect(!HTTPWireCodec.isInitializeRequest(body: bytes("not json")))
        #expect(!HTTPWireCodec.isInitializeRequest(body: Data()))
        // "initialize" appearing as a VALUE elsewhere must not trip the sniff.
        #expect(!HTTPWireCodec.isInitializeRequest(body: bytes(#"{"method":"x","note":"initialize"}"#)))
    }
}
