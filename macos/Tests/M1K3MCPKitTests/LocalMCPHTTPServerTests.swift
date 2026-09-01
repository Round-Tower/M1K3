//
//  LocalMCPHTTPServerTests.swift
//  M1K3MCPKitTests
//
//  Live loopback round-trips through the whole in-app stack: NWListener →
//  HTTPWireCodec → StatelessHTTPServerTransport → SDK Server → registry.
//  Includes the second-initialize session rebuild — the SDK Server rejects a
//  repeat initialize for its lifetime, so this is the test that keeps a second
//  `claude` session from 400ing until app restart.
//

import Foundation
@testable import M1K3MCPKit
import MCP
import Testing

private func makeServer(port: UInt16) -> LocalMCPHTTPServer {
    LocalMCPHTTPServer(port: port) {
        let registry = MCPToolRegistry([
            MCPToolDefinition(
                tool: Tool(name: "alpha", description: "first", inputSchema: ["type": "object"]),
                handler: { _ in "alpha says hi" }
            ),
        ])
        let transport = StatelessHTTPServerTransport()
        let server = await makeM1K3Server(registry: registry)
        try await server.start(transport: transport)
        return (server, transport)
    }
}

private func makeServerWithSlowAndFastTools(port: UInt16) -> LocalMCPHTTPServer {
    LocalMCPHTTPServer(port: port) {
        let registry = MCPToolRegistry([
            MCPToolDefinition(
                tool: Tool(name: "slow", description: "slow", inputSchema: ["type": "object"]),
                handler: { _ in
                    try await Task.sleep(for: .milliseconds(400))
                    return "slow-done"
                }
            ),
            MCPToolDefinition(
                tool: Tool(name: "fast", description: "fast", inputSchema: ["type": "object"]),
                handler: { _ in "fast-done" }
            ),
        ])
        let transport = StatelessHTTPServerTransport()
        let server = await makeM1K3Server(registry: registry)
        try await server.start(transport: transport)
        return (server, transport)
    }
}

private func post(_ json: String, port: UInt16) async throws -> (status: Int, body: String) {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = Data(json.utf8)
    request.timeoutInterval = 10
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? -1
    return (status, String(decoding: data, as: UTF8.self))
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func incrementAndGet() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

private let initializeBody = #"""
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"wire-test","version":"0"}}}
"""#

struct LocalMCPHTTPServerTests {
    @Test("initialize, list tools, and re-initialize round-trip over real loopback HTTP")
    func fullRoundTrip() async throws {
        let port = UInt16.random(in: 52000 ... 59000)
        let server = makeServer(port: port)
        try await server.start()
        defer { Task { await server.stop() } }
        // No sleep: start() now awaits the listener's real bind before returning.

        let initResponse = try await post(initializeBody, port: port)
        #expect(initResponse.status == 200)
        #expect(initResponse.body.contains("m1k3"))

        let listResponse = try await post(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#, port: port)
        #expect(listResponse.status == 200)
        #expect(listResponse.body.contains("alpha"))

        // A SECOND initialize (fresh client) must succeed via session rebuild,
        // and the rebuilt session must still serve tools.
        let reinitResponse = try await post(initializeBody, port: port)
        #expect(reinitResponse.status == 200)
        #expect(reinitResponse.body.contains("m1k3"))
        #expect(!reinitResponse.body.contains("already initialized"))

        let relistResponse = try await post(#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#, port: port)
        #expect(relistResponse.status == 200)
        #expect(relistResponse.body.contains("alpha"))

        await server.stop()
        let stopped = await server.isRunning
        #expect(!stopped)
    }

    @Test("two concurrent requests sharing id=1 both return — no response-waiter collision (#176)")
    func concurrentSameIDNoCollision() async throws {
        // Pre-fix, the shared transport keyed responseWaiters by the client id,
        // so the fast request's waiter[1] clobbered the slow request's, orphaning
        // the slow one until timeout. The per-request id remap must let BOTH
        // return with the correct id echoed back.
        let port = UInt16.random(in: 52000 ... 59000)
        let server = makeServerWithSlowAndFastTools(port: port)
        try await server.start()
        defer { Task { await server.stop() } }

        async let slow = post(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"slow"}}"#, port: port)
        // Let the slow request register its waiter first; the fast one (same id)
        // would then clobber it in the buggy version.
        try await Task.sleep(for: .milliseconds(60))
        async let fast = post(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"fast"}}"#, port: port)

        let (slowResp, fastResp) = try await (slow, fast)
        #expect(slowResp.status == 200)
        #expect(slowResp.body.contains("slow-done"))
        #expect(fastResp.status == 200)
        #expect(fastResp.body.contains("fast-done"))
        // Each client sees its own id (1) echoed, not the internal token.
        #expect(slowResp.body.contains("\"id\":1") || slowResp.body.contains("\"id\": 1"))
        #expect(fastResp.body.contains("\"id\":1") || fastResp.body.contains("\"id\": 1"))

        await server.stop()
    }

    @Test("initialize reports the self-declared client name; no clientInfo reports nil")
    func clientInitializeWiring() async throws {
        // The one genuinely new piece of logic in the identity capture is the
        // CALL SITE (respond → onClientInitialize) — HTTPWireCodec.clientName
        // and StampingLogSink are covered in isolation, but a silently
        // never-firing callback would ship undetected without this
        // (PR #137 review fold).
        final class NameBox: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [String?] = []
            func append(_ value: String?) {
                lock.withLock { values.append(value) }
            }

            func read() -> [String?] {
                lock.withLock { values }
            }
        }
        let box = NameBox()
        let port = UInt16.random(in: 52000 ... 59000)
        let server = LocalMCPHTTPServer(
            port: port,
            onClientInitialize: { box.append($0) }
        ) {
            let registry = MCPToolRegistry([
                MCPToolDefinition(
                    tool: Tool(name: "alpha", description: "first", inputSchema: ["type": "object"]),
                    handler: { _ in "alpha says hi" }
                ),
            ])
            let transport = StatelessHTTPServerTransport()
            let server = await makeM1K3Server(registry: registry)
            try await server.start(transport: transport)
            return (server, transport)
        }
        try await server.start()
        defer { Task { await server.stop() } }

        _ = try await post(initializeBody, port: port)
        let anonymous = #"{"jsonrpc":"2.0","id":9,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{}}}"#
        _ = try await post(anonymous, port: port)
        #expect(box.read() == ["wire-test", nil])
        await server.stop()
    }

    @Test("a session-rebuild failure stops the server honestly instead of zombie 500s")
    func rebuildFailureStopsServer() async throws {
        let port = UInt16.random(in: 52000 ... 59000)
        let attempts = Counter()
        let stopped = Counter()
        let server = LocalMCPHTTPServer(
            port: port,
            onAbnormalStop: { _ in stopped.increment() }
        ) {
            if attempts.incrementAndGet() > 1 { throw MCPVoiceError("factory down") }
            let transport = StatelessHTTPServerTransport()
            let registry = MCPToolRegistry([])
            let mcpServer = await makeM1K3Server(registry: registry)
            try await mcpServer.start(transport: transport)
            return (mcpServer, transport)
        }
        try await server.start()

        _ = try await post(initializeBody, port: port)
        // Second initialize → factory throws → server must stop, not zombie.
        let failed = try? await post(initializeBody, port: port)
        if let failed { #expect(failed.status == 500) } // connection may also just close

        try await Task.sleep(for: .milliseconds(100))
        let running = await server.isRunning
        #expect(!running)
        #expect(stopped.value == 1)
    }

    @Test("a second server on the same port throws instead of falsely reporting Running")
    func portConflictThrows() async throws {
        // The bug: start() ignored the async bind result, so a second instance on
        // an already-held port set isRunning=true and the host showed "Running"
        // while no socket ever bound. start() must now surface EADDRINUSE.
        let port = UInt16.random(in: 52000 ... 59000)
        let first = makeServer(port: port)
        try await first.start()
        defer { Task { await first.stop() } }

        let second = makeServer(port: port)
        await #expect(throws: (any Error).self) {
            try await second.start()
        }
        let secondRunning = await second.isRunning
        #expect(!secondRunning)
    }

    @Test("start() returns only once bound — an immediate request needs no sleep")
    func startAwaitsBind() async throws {
        let port = UInt16.random(in: 52000 ... 59000)
        let server = makeServer(port: port)
        try await server.start()
        defer { Task { await server.stop() } }
        // No Task.sleep: start() awaited .ready, so this lands immediately.
        let response = try await post(initializeBody, port: port)
        #expect(response.status == 200)
    }

    @Test("tool calls dispatch through the live stack")
    func toolCall() async throws {
        let port = UInt16.random(in: 52000 ... 59000)
        let server = makeServer(port: port)
        try await server.start()

        _ = try await post(initializeBody, port: port)
        let call = try await post(
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"alpha","arguments":{}}}"#,
            port: port
        )
        #expect(call.status == 200)
        #expect(call.body.contains("alpha says hi"))

        await server.stop()
    }
}
