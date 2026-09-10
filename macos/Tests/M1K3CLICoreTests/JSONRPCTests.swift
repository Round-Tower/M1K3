//
//  JSONRPCTests.swift
//  M1K3CLICoreTests
//
//  The two frames `m1k3` puts on the wire and the four answers it can get
//  back. Byte-pinned rather than field-checked: the server on the other end is
//  a strict MCP SDK, and "ids as integers" is the kind of thing that only
//  breaks in production if nobody wrote it down.
//
//  Signed: Kev + claude-opus-5, 2026-09-11, Confidence 0.9 (the wire shapes
//  are read off the SDK the app links; the not-initialized sentinel is matched
//  on the SDK's own wording, which is the one brittle edge). Prior: Unknown.
//

import Foundation
@testable import M1K3CLICore
import Testing

struct JSONRPCTests {
    private func text(_ data: Data) throws -> String {
        try #require(String(data: data, encoding: .utf8))
    }

    @Test("tools/call carries the tool name and its arguments, with an integer id")
    func toolsCall() throws {
        let data = try JSONRPC.toolsCall(name: "speak", arguments: ["text": .string("hi")], id: 7)
        #expect(try text(data) == #"""
        {"id":7,"jsonrpc":"2.0","method":"tools/call","params":{"arguments":{"text":"hi"},"name":"speak"}}
        """#)
    }

    @Test("a tool with no arguments still sends an object, not null")
    func toolsCallNoArguments() throws {
        let data = try JSONRPC.toolsCall(name: "get_status", arguments: [:], id: 1)
        #expect(try text(data).contains(#""arguments":{}"#))
    }

    @Test("initialize names the client — the name the notch HUD captions")
    func initialize() throws {
        let data = try JSONRPC.initialize(clientName: "m1k3-cli", clientVersion: "1.0.0", id: 1)
        let line = try text(data)
        #expect(line.contains(#""method":"initialize""#))
        #expect(line.contains(#""name":"m1k3-cli""#))
        #expect(line.contains(#""version":"1.0.0""#))
        #expect(line.contains(#""protocolVersion":"\#(JSONRPC.protocolVersion)""#))
        #expect(line.contains(#""capabilities":{}"#))
        #expect(line.contains(#""id":1"#))
    }

    @Test("the default client name is m1k3-cli")
    func defaultClientName() {
        #expect(JSONRPC.defaultClientName == "m1k3-cli")
    }

    // MARK: - Replies

    @Test("a result's text content comes back as text")
    func replyText() {
        let data = Data(#"""
        {"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"Speaking."}]}}
        """#.utf8)
        #expect(JSONRPC.Reply.parse(data) == .text("Speaking."))
    }

    @Test("several text parts join on newlines; non-text parts are ignored")
    func replyJoinsText() {
        let data = Data(#"""
        {"result":{"content":[{"type":"text","text":"one"},{"type":"image","data":"…"},{"type":"text","text":"two"}]}}
        """#.utf8)
        #expect(JSONRPC.Reply.parse(data) == .text("one\ntwo"))
    }

    @Test("a JSON-RPC error comes back with its code and message")
    func replyError() {
        let data = Data(#"""
        {"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found: nope"}}
        """#.utf8)
        #expect(JSONRPC.Reply.parse(data) == .error(code: -32601, message: "Method not found: nope"))
    }

    @Test("the SDK's not-initialized refusal is its own case — it is recoverable, an error is not")
    func replyNotInitialized() {
        let data = Data(#"""
        {"jsonrpc":"2.0","id":1,"error":{"code":-32600,"message":"Invalid Request: Server is not initialized"}}
        """#.utf8)
        #expect(JSONRPC.Reply.parse(data) == .notInitialized)
    }

    @Test("a tool that failed reports isError, not a JSON-RPC error — still an error to us")
    func replyToolFailure() {
        let data = Data(#"""
        {"result":{"isError":true,"content":[{"type":"text","text":"Unknown tool: yodel"}]}}
        """#.utf8)
        #expect(JSONRPC.Reply.parse(data)
            == .error(code: JSONRPC.Reply.toolFailureCode, message: "Unknown tool: yodel"))
    }

    @Test("an unreadable answer is an error, never a silent empty success")
    func replyMalformed() {
        let data = Data("not json at all".utf8)
        guard case let .error(code, message) = JSONRPC.Reply.parse(data) else {
            Issue.record("expected an error")
            return
        }
        #expect(code == JSONRPC.Reply.parseErrorCode)
        #expect(!message.isEmpty)
    }

    @Test("a result with no content at all reads as empty text, not as a failure")
    func replyEmptyResult() {
        let data = Data(#"{"result":{"content":[]}}"#.utf8)
        #expect(JSONRPC.Reply.parse(data) == .text(""))
    }
}
