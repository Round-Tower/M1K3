//
//  LocalMCPHTTPServer.swift
//  M1K3MCPKit
//
//  Loopback-only HTTP/1.1 listener that fronts the in-app MCP server. The MCP
//  SDK's StatelessHTTPServerTransport is framework-agnostic (it answers
//  HTTPRequest values; it binds no socket), so this NWListener shell feeds it:
//  accumulate bytes → HTTPWireCodec.parseRequest → transport.handleRequest →
//  HTTPWireCodec.encode → write → close. One request per connection.
//
//  Session rebuild: the SDK Server rejects a second `initialize` for its
//  lifetime, so a fresh client connecting would 400 forever. We sniff
//  initialize POSTs and rebuild the (Server, transport) pair via the injected
//  factory — the previous client's session simply ends (documented v1 limit:
//  one MCP client at a time).
//
//  Bound to 127.0.0.1 explicitly — never an interface address. The OS-level
//  guarantee is the privacy story: no LAN exposure, ever.
//
//  Signed: Kev + claude-fable-5, 2026-06-11, Confidence 0.8 (wire layer is
//  test-pinned; the NWListener shell is verify-by-launch — exercised live via
//  `claude mcp add`). Prior: Unknown.
//  Review: claude-fable-5, 2026-08-19 — added `onClientInitialize` (reports each
//  initialize's self-declared client name for the Agent Log identity stamp;
//  call-site wiring test-pinned in LocalMCPHTTPServerTests).
//

import Foundation
import MCP
import Network
import os

public actor LocalMCPHTTPServer {
    public typealias SessionFactory = @Sendable () async throws -> (Server, StatelessHTTPServerTransport)

    private static let log = Logger(subsystem: "app.m1k3", category: "mcp")
    private let port: UInt16
    private let makeSession: SessionFactory
    /// Called when the server stops itself (session rebuild failed) — the
    /// host UI uses it to show an honest status instead of a stale "Running".
    private let onAbnormalStop: (@Sendable (String) -> Void)?
    /// Called on every initialize with the client's self-reported name (nil
    /// when it sent none) — the host stamps it onto the opt-in Agent
    /// Interaction Log so the timeline can fold visits per client. Fires on
    /// EVERY initialize, including a re-initialize with no name, so a stale
    /// identity can't outlive its session.
    private let onClientInitialize: (@Sendable (String?) -> Void)?
    private var listener: NWListener?
    private var session: (server: Server, transport: StatelessHTTPServerTransport)?

    /// Monotonic source of process-unique JSON-RPC ids. The shared stateless
    /// transport routes responses by request id GLOBALLY; clients all start at
    /// id 1, so without this two concurrent requests collide and orphan each
    /// other (issue #176). Rewriting every request to a unique id before the
    /// transport sees it makes the waiter keys collision-proof. Actor-isolated
    /// → the increment needs no extra lock.
    private var requestIDCounter: UInt64 = 0

    public private(set) var isRunning = false

    public init(
        port: UInt16,
        onAbnormalStop: (@Sendable (String) -> Void)? = nil,
        onClientInitialize: (@Sendable (String?) -> Void)? = nil,
        makeSession: @escaping SessionFactory
    ) {
        self.port = port
        self.onAbnormalStop = onAbnormalStop
        self.onClientInitialize = onClientInitialize
        self.makeSession = makeSession
    }

    /// Bind the loopback listener and serve until `stop()`.
    ///
    /// Awaits the listener's REAL bind result before returning: `listener.start`
    /// is fire-and-forget and delivers a bind failure (e.g. EADDRINUSE when a
    /// second instance already holds the port) asynchronously on
    /// `stateUpdateHandler`. Without awaiting `.ready`, start() returned success
    /// while the socket never bound — the host then showed a stale "Running".
    public func start() async throws {
        guard !isRunning else { return }
        let parameters = NWParameters.tcp
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw MCPVoiceError("invalid port \(port)")
        }
        // Loopback pin: connections from other machines never reach us.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            Task { await self.handle(connection) }
        }

        try await awaitListenerReady(listener)

        // Bound. Swap in the long-lived handler: a listener that dies mid-session
        // must flip the host status off (parity with the session-rebuild honesty
        // path). Route only genuine failures — normal stop() fires `.cancelled`,
        // which must NOT be reported as an abnormal stop.
        listener.stateUpdateHandler = { [weak self] state in
            if case let .failed(error) = state {
                Task { await self?.handleListenerFailure(error) }
            }
        }
        self.listener = listener
        session = try await makeSession()
        isRunning = true
    }

    /// Suspend until the listener binds (`.ready`) or fail fast on a bind error
    /// (`.failed` / `.waiting` — EADDRINUSE surfaces as `.waiting`). Guards against
    /// a double-resume since `stateUpdateHandler` fires repeatedly, and cancels the
    /// listener on failure so a rejected bind can't leak.
    private func awaitListenerReady(_ listener: NWListener) async throws {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resumed = OSAllocatedUnfairLock(initialState: false)
                let resumeOnce: @Sendable (Result<Void, Error>) -> Void = { result in
                    let firstTime = resumed.withLock { done -> Bool in
                        if done { return false }
                        done = true
                        return true
                    }
                    if firstTime { continuation.resume(with: result) }
                }
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: resumeOnce(.success(()))
                    case let .failed(error): resumeOnce(.failure(error))
                    case let .waiting(error): resumeOnce(.failure(error))
                    case .cancelled: resumeOnce(.failure(CancellationError()))
                    default: break
                    }
                }
                listener.start(queue: .global(qos: .userInitiated))
            }
        } catch {
            listener.cancel()
            throw error
        }
    }

    /// A listener that failed after it was serving — tear down honestly so the
    /// host UI stops claiming "Running". No-op if we already stopped cleanly.
    private func handleListenerFailure(_ error: NWError) async {
        guard isRunning else { return }
        Self.log.error("MCP listener failed: \(error.localizedDescription, privacy: .public)")
        await stop()
        onAbnormalStop?("MCP listener failed: \(error.localizedDescription)")
    }

    public func stop() async {
        listener?.cancel()
        listener = nil
        if let session {
            await session.server.stop()
            await session.transport.disconnect()
        }
        session = nil
        isRunning = false
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) async {
        connection.start(queue: .global(qos: .userInitiated))
        var buffer = Data()
        while isRunning {
            guard let chunk = await receiveChunk(connection) else { break }
            buffer.append(chunk)
            guard let parsed = HTTPWireCodec.parseRequest(buffer) else {
                if buffer.count > 1_048_576 {
                    // Dropped silently before — a client whose request never lands
                    // looked identical to a hung server.
                    Self.log.notice("dropped oversized request (\(buffer.count) bytes) before parse")
                    break
                }
                continue
            }
            let response = await respond(to: parsed.request)
            await send(HTTPWireCodec.encode(response), over: connection)
            break // Connection: close — one request per connection
        }
        connection.cancel()
    }

    private func respond(to request: HTTPRequest) async -> HTTPResponse {
        // A new client's initialize must land on a FRESH SDK server.
        if let body = request.body, HTTPWireCodec.isInitializeRequest(body: body) {
            onClientInitialize?(HTTPWireCodec.clientName(fromInitializeBody: body))
            if let session {
                await session.server.stop()
                await session.transport.disconnect()
            }
            session = nil
            do {
                session = try await makeSession()
            } catch {
                // A factory throw must not leave a zombie listener returning
                // 500s while claiming to run — stop honestly and tell the host.
                Self.log.error("MCP session rebuild failed: \(error.localizedDescription, privacy: .public)")
                await stop()
                onAbnormalStop?("MCP session rebuild failed: \(error)")
                return .error(statusCode: 500, MCPError.internalError("MCP session rebuild failed"))
            }
        }
        guard let transport = session?.transport else {
            return .error(statusCode: 500, MCPError.internalError("MCP session unavailable"))
        }

        // Isolate this request's response waiter from client id collisions:
        // rewrite its JSON-RPC id to a process-unique token before the shared
        // transport registers a waiter for it, then map the response's id back
        // to what the client sent. A notification (no id) is passed straight
        // through — it registers no waiter, so nothing can collide. See #176.
        guard
            let body = request.body,
            let clientID = HTTPWireCodec.requestID(inBody: body)
        else {
            return await transport.handleRequest(request)
        }
        requestIDCounter &+= 1
        let uniqueID = JSONRPCID.string("m1k3#\(requestIDCounter)")
        guard let rewrittenBody = HTTPWireCodec.replacingID(inBody: body, with: uniqueID) else {
            return await transport.handleRequest(request)
        }
        let rewrittenRequest = HTTPRequest(
            method: request.method, headers: request.headers,
            body: rewrittenBody, path: request.path
        )
        let response = await transport.handleRequest(rewrittenRequest)
        return HTTPWireCodec.replacingResponseID(response, with: clientID)
    }

    private func receiveChunk(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { data, _, isComplete, error in
                if let data, !data.isEmpty, error == nil {
                    continuation.resume(returning: data)
                } else {
                    _ = isComplete
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func send(_ data: Data, over connection: NWConnection) async {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { _ in
                continuation.resume()
            })
        }
    }
}
