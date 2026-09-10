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
//  Review: Kev + claude-fable-5.1, 2026-09-04 (#190) — every test binds through
//  `startOnFreePort`: the old 52000…59000 pick sat INSIDE macOS's ephemeral
//  range and collided with the Xcode Cloud VM's own outbound sockets
//  (EADDRINUSE killed the deploy gate in runs #270 and #280). Ports now come
//  from below that range, and a bind collision retries on a fresh port.
//  Review: Kev + claude-fable-5.1, 2026-09-10 — raw-socket forgeries through
//  the real listener (URLSession rewrites Host, so `rawPost` builds the bytes):
//  a forged Host / text/plain / foreign Origin / other path is refused at the
//  door and the live session survives (its own tool name still listed); the
//  read deadline closes an idle socket and does NOT clock a slow tool call.
//

import Foundation
@testable import M1K3MCPKit
import MCP
import Network
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

/// Every loopback test binds a fresh port. The old pick, 52000…59000, sits
/// INSIDE macOS's ephemeral range (49152–65535): on the Xcode Cloud VM the
/// package-resolution and upload sockets live there, and a listener landing on
/// one of them throws EADDRINUSE (POSIX 48) — runs #270 and #280 died in this
/// suite that way (#190). Pick below the ephemeral range, and if a bind still
/// collides, build a fresh server on a fresh port rather than fail the run.
private func startOnFreePort(
    attempts: Int = 5, _ make: (UInt16) -> LocalMCPHTTPServer
) async throws -> (server: LocalMCPHTTPServer, port: UInt16) {
    var lastError: (any Error)?
    for _ in 0 ..< attempts {
        let port = UInt16.random(in: 20000 ... 40000)
        let server = make(port)
        do {
            try await server.start()
            return (server, port)
        } catch let NWError.posix(code) where code == .EADDRINUSE {
            lastError = NWError.posix(code)
        }
    }
    throw lastError ?? MCPVoiceError("no free loopback port after \(attempts) attempts")
}

/// Hand-built HTTP/1.1 POST over a raw socket, so the test controls the Host
/// and Origin headers byte-for-byte (URLSession rewrites Host). Reads until
/// the server closes the connection (`Connection: close` is the wire contract).
private func rawPost(
    _ json: String, port: UInt16, host: String, origin: String? = nil,
    contentType: String = "application/json", path: String = "/mcp"
) async throws -> (status: Int, body: String) {
    let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    connection.start(queue: .global(qos: .userInitiated))
    defer { connection.cancel() }
    var head = "POST \(path) HTTP/1.1\r\nHost: \(host)\r\nContent-Type: \(contentType)\r\n"
    head += "Accept: application/json\r\nContent-Length: \(json.utf8.count)\r\nConnection: close\r\n"
    if let origin { head += "Origin: \(origin)\r\n" }
    head += "\r\n"
    let payload = Data(head.utf8) + Data(json.utf8)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        connection.send(content: payload, completion: .contentProcessed { error in
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        })
    }
    var received = Data()
    while true {
        let chunk: Data? = try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: data) }
            }
        }
        guard let chunk, !chunk.isEmpty else { break }
        received.append(chunk)
    }
    let text = String(decoding: received, as: UTF8.self)
    let statusLine = text.components(separatedBy: "\r\n").first ?? ""
    let status = Int(statusLine.split(separator: " ").dropFirst().first ?? "") ?? -1
    let body = text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
    return (status, body)
}

private let initializeBody = #"""
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"wire-test","version":"0"}}}
"""#

struct LocalMCPHTTPServerTests {
    @Test("initialize, list tools, and re-initialize round-trip over real loopback HTTP")
    func fullRoundTrip() async throws {
        let (server, port) = try await startOnFreePort { makeServer(port: $0) }
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
        let (server, port) = try await startOnFreePort { makeServerWithSlowAndFastTools(port: $0) }
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
        let (server, port) = try await startOnFreePort { port in
            LocalMCPHTTPServer(
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
        }
        defer { Task { await server.stop() } }

        _ = try await post(initializeBody, port: port)
        let anonymous = #"{"jsonrpc":"2.0","id":9,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{}}}"#
        _ = try await post(anonymous, port: port)
        #expect(box.read() == ["wire-test", nil])
        await server.stop()
    }

    @Test("a session-rebuild failure stops the server honestly instead of zombie 500s")
    func rebuildFailureStopsServer() async throws {
        let attempts = Counter()
        let stopped = Counter()
        let (server, port) = try await startOnFreePort { port in
            LocalMCPHTTPServer(
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
        }

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
        let (first, port) = try await startOnFreePort { makeServer(port: $0) }
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
        let (server, port) = try await startOnFreePort { makeServer(port: $0) }
        defer { Task { await server.stop() } }
        // No Task.sleep: start() awaited .ready, so this lands immediately.
        let response = try await post(initializeBody, port: port)
        #expect(response.status == 200)
    }

    @Test("tool calls dispatch through the live stack")
    func toolCall() async throws {
        let (server, port) = try await startOnFreePort { makeServer(port: $0) }

        _ = try await post(initializeBody, port: port)
        let call = try await post(
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"alpha","arguments":{}}}"#,
            port: port
        )
        #expect(call.status == 200)
        #expect(call.body.contains("alpha says hi"))

        await server.stop()
    }

    @Test("a forged Host on an initialize is refused at the door and never rebuilds the live session")
    func forgedHostInitializeNeverRebuildsSession() async throws {
        let builds = Counter()
        let (server, port) = try await startOnFreePort { port in
            LocalMCPHTTPServer(port: port) {
                // Each build names its tool after its own number, so the tools/list
                // below proves the ORIGINAL session answered — a rebuilt one would
                // list a different name.
                let build = builds.incrementAndGet()
                let registry = MCPToolRegistry([
                    MCPToolDefinition(
                        tool: Tool(name: "session-\(build)", description: "build \(build)", inputSchema: ["type": "object"]),
                        handler: { _ in "hi" }
                    ),
                ])
                let transport = StatelessHTTPServerTransport()
                let mcp = await makeM1K3Server(registry: registry)
                try await mcp.start(transport: transport)
                return (mcp, transport)
            }
        }
        defer { Task { await server.stop() } }
        _ = try await post(initializeBody, port: port)
        let before = builds.value

        let forged = try await rawPost(initializeBody, port: port, host: "attacker.example:\(port)")
        #expect(forged.status == 403, "status \(forged.status) body \(forged.body)")
        #expect(builds.value == before, "a refused initialize must not tear down the live session")

        // The session that was live before the forgery still answers, by name.
        let list = try await post(#"{"jsonrpc":"2.0","id":9,"method":"tools/list"}"#, port: port)
        #expect(list.status == 200)
        #expect(list.body.contains("session-\(before)"), Comment(rawValue: list.body))
        #expect(builds.value == before)
    }

    @Test("the read deadline clocks the request bytes only — a slow tool call is not cut off")
    func readDeadlineExcludesToolTime() async throws {
        let (server, port) = try await startOnFreePort { port in
            LocalMCPHTTPServer(port: port, readDeadline: 0.3) {
                let registry = MCPToolRegistry([
                    MCPToolDefinition(
                        tool: Tool(name: "slow", description: "sleeps", inputSchema: ["type": "object"]),
                        handler: { _ in
                            try await Task.sleep(for: .milliseconds(800))
                            return "done"
                        }
                    ),
                ])
                let transport = StatelessHTTPServerTransport()
                let mcp = await makeM1K3Server(registry: registry)
                try await mcp.start(transport: transport)
                return (mcp, transport)
            }
        }
        defer { Task { await server.stop() } }
        _ = try await post(initializeBody, port: port)
        let reply = try await post(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"slow"}}"#, port: port)
        #expect(reply.status == 200, "status \(reply.status) body \(reply.body)")
        #expect(reply.body.contains("done"))
    }

    @Test("a no-preflight text/plain POST is refused at the door — the live session survives it")
    func simpleCrossSitePostNeverRebuildsSession() async throws {
        let builds = Counter()
        let (server, port) = try await startOnFreePort { port in
            LocalMCPHTTPServer(port: port) {
                builds.increment()
                let transport = StatelessHTTPServerTransport()
                let mcp = await makeM1K3Server(registry: MCPToolRegistry([]))
                try await mcp.start(transport: transport)
                return (mcp, transport)
            }
        }
        defer { Task { await server.stop() } }
        _ = try await post(initializeBody, port: port)
        let before = builds.value
        let refused = try await rawPost(initializeBody, port: port, host: "127.0.0.1:\(port)", contentType: "text/plain")
        #expect(refused.status == 415, "status \(refused.status) body \(refused.body)")
        #expect(builds.value == before)
    }

    @Test("only /mcp is served; anything else is 404 before the sniff")
    func otherPathsAreNotFound() async throws {
        let (server, port) = try await startOnFreePort { makeServer(port: $0) }
        defer { Task { await server.stop() } }
        let refused = try await rawPost(initializeBody, port: port, host: "127.0.0.1:\(port)", path: "/")
        #expect(refused.status == 404, "status \(refused.status) body \(refused.body)")
    }

    @Test("a socket that never sends a complete request is closed at the read deadline")
    func idleSocketIsClosed() async throws {
        let (server, port) = try await startOnFreePort { port in
            LocalMCPHTTPServer(port: port, readDeadline: 0.5) {
                let transport = StatelessHTTPServerTransport()
                let mcp = await makeM1K3Server(registry: MCPToolRegistry([]))
                try await mcp.start(transport: transport)
                return (mcp, transport)
            }
        }
        defer { Task { await server.stop() } }
        let connection = try NWConnection(host: "127.0.0.1", port: #require(NWEndpoint.Port(rawValue: port)), using: .tcp)
        connection.start(queue: .global(qos: .userInitiated))
        defer { connection.cancel() }
        // Half a request, then silence.
        let started = ContinuousClock.now
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\n".utf8), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
        // Watchdog: if the server never closes, close it ourselves at 3 s so the
        // receive below returns and the elapsed-time assertion fails honestly.
        let watchdog = Task {
            try await Task.sleep(for: .seconds(3))
            connection.cancel()
        }
        let closed: Bool = await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, isComplete, error in
                continuation.resume(returning: isComplete || error != nil || data == nil)
            }
        }
        watchdog.cancel()
        #expect(closed, "the server should have closed the idle connection")
        #expect(ContinuousClock.now - started < .seconds(2), "closed by the watchdog, not the server")
    }

    @Test("a browser page from a foreign origin is refused even with a correct Host")
    func forgedOriginRefused() async throws {
        let (server, port) = try await startOnFreePort { makeServer(port: $0) }
        defer { Task { await server.stop() } }
        let refused = try await rawPost(initializeBody, port: port, host: "127.0.0.1:\(port)", origin: "https://evil.example")
        #expect(refused.status == 403, "status \(refused.status) body \(refused.body)")
        let admitted = try await rawPost(initializeBody, port: port, host: "localhost:\(port)", origin: "http://localhost:3000")
        #expect(admitted.status == 200, "status \(admitted.status) body \(admitted.body)")
    }
}
