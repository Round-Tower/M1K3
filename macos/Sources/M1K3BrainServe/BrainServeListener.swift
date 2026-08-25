//
//  BrainServeListener.swift
//  M1K3BrainServe
//
//  The Brain at Home LAN listener: TLS-PSK (BrainServeTLS — the spike-proven
//  ECDHE_PSK arm) over NWListener, serving four routes to PAIRED devices
//  only:
//
//    POST /v1/generate  — SSE token stream off the injected generate closure
//    GET  /v1/health    — small JSON status
//    POST /mcp          — the SCOPED MCP session (nil handler = 404)
//    POST /v1/pair      — pairing-listener-only (nil handler = 404)
//
//  Every route sits behind the PSK handshake (audit B4 — the TLS layer
//  refuses unpaired clients before a byte of HTTP exists; spike-proven zero
//  application bytes). Structure mirrors LocalMCPHTTPServer: accumulate →
//  HTTPWireCodec.parseRequest → route → respond → close. One request per
//  connection; an SSE response is the one place the response is written as
//  multiple flushed sends (spike A2: the client sees them incrementally).
//
//  The MAIN listener (app wiring) never carries pairing candidates' keys and
//  passes pair: nil; the short-lived PAIRING listener carries ONLY the
//  candidate key and passes generate/mcp handlers that refuse — the B2
//  "nothing served before Approve" guarantee is that structural split, not a
//  runtime check.
//
//  Interface pinning: prohibits cellular + `.other` (utun/VPN tunnels) and
//  rejects non-private source addresses at accept (PrivateSourcePolicy) —
//  audit B3. The live Tailscale-unreachable check remains hardware-owed.
//
//  Signed: Kev + claude-fable-5, 2026-08-19, Confidence 0.85 (routes/frames/
//  policies pure-tested; the listener itself is pinned by real loopback
//  TLS-PSK round-trips in BrainServeListenerTests — the LocalMCPHTTPServer
//  test precedent — incl. wrong-PSK and plain-TCP negative paths; LAN
//  behaviour on real hardware is verify-owed). Prior: none (new file).
//

import Foundation
import M1K3BrainLink
import M1K3MCPKit
import MCP
import Network
import os

/// App-injected behaviour behind the routes. Closures, not protocols — the
/// VoiceToolHandlers pattern; the app composes them over its live seams.
public struct BrainServeHandlers: Sendable {
    /// Admission decision for a NEW remote generation (busy/thermal → 429).
    public var admit: @Sendable () async -> RemoteTurnDecision
    /// The token stream for an admitted request. The stream ending ends the
    /// response; a client hangup cancels iteration via the failed send.
    /// nil = raw generation unavailable right now → 503 (distinguishable from
    /// a model that said nothing — the 2026-08-19 audit's finding-1 fold).
    public var generate: @Sendable (GenerateRequest) async -> AsyncStream<String>?
    public var healthJSON: @Sendable () async -> String
    /// The scoped MCP session (nil = route disabled → 404).
    public var mcp: (@Sendable (HTTPRequest) async -> HTTPResponse)?
    /// Pairing request (pairing listener only; nil = 404). Returns response
    /// JSON — "pending approval" — the commit happens app-side on Approve.
    public var pair: (@Sendable (PairRequest) async -> String)?

    public init(
        admit: @escaping @Sendable () async -> RemoteTurnDecision,
        generate: @escaping @Sendable (GenerateRequest) async -> AsyncStream<String>?,
        healthJSON: @escaping @Sendable () async -> String,
        mcp: (@Sendable (HTTPRequest) async -> HTTPResponse)? = nil,
        pair: (@Sendable (PairRequest) async -> String)? = nil
    ) {
        self.admit = admit
        self.generate = generate
        self.healthJSON = healthJSON
        self.mcp = mcp
        self.pair = pair
    }
}

public actor BrainServeListener {
    private static let log = Logger(subsystem: "app.m1k3", category: "brain-serve")

    private let port: UInt16
    private let credentials: [PSKCredential]
    private let handlers: BrainServeHandlers
    private let onAbnormalStop: (@Sendable (String) -> Void)?
    /// A connection must deliver a parseable request within this window or be
    /// dropped — the "hold the socket, never speak" (Slowloris) guard. An SSE
    /// stream already serving is unaffected (the deadline dies at parse).
    private let requestTimeout: Duration
    /// Cap on concurrently open connections (pre- and post-handshake alike) —
    /// resource-exhaustion bound, independent of authentication.
    private let maxConnections: Int
    private var listener: NWListener?
    /// EVERY accepted connection, so stop()/revoke tears all of them down —
    /// not just in-flight SSE streams (2026-08-19 audit, finding 6).
    private var openConnections: [ObjectIdentifier: NWConnection] = [:]
    /// Connections with an SSE stream in flight — cancelled by preemption,
    /// and the single-flight gate for remote generation (finding 4).
    private var activeStreamConnections: [ObjectIdentifier: NWConnection] = [:]

    public private(set) var isRunning = false
    /// The bound port (differs from `port` when 0 = ephemeral was asked).
    public private(set) var boundPort: UInt16?

    public init(
        port: UInt16,
        credentials: [PSKCredential],
        handlers: BrainServeHandlers,
        onAbnormalStop: (@Sendable (String) -> Void)? = nil,
        requestTimeout: Duration = .seconds(10),
        maxConnections: Int = 16
    ) {
        self.port = port
        self.credentials = credentials
        self.handlers = handlers
        self.onAbnormalStop = onAbnormalStop
        self.requestTimeout = requestTimeout
        self.maxConnections = maxConnections
    }

    public func start() async throws {
        guard !isRunning else { return }
        guard !credentials.isEmpty else {
            throw MCPVoiceError("brain serve: no paired devices — nothing to listen for")
        }
        let parameters = NWParameters(tls: BrainServeTLS.options(credentials: credentials))
        // Audit B3: never cellular, never tunnel-class interfaces. (Loopback
        // stays allowed — it's how the test suite and probes exercise this.)
        parameters.prohibitedInterfaceTypes = [.cellular, .other]
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw MCPVoiceError("invalid port \(port)")
        }
        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            // Accept-time source gate (B3's second half) — fail CLOSED: an
            // endpoint shape this doesn't recognise is refused, not admitted
            // (2026-08-19 audit, finding 3). Inbound TCP accepts are always
            // .hostPort today; this guard is for the day that stops being true.
            guard case let .hostPort(host, _) = connection.endpoint,
                  PrivateSourcePolicy.isPrivate(host: "\(host)")
            else {
                Self.log.notice("brain serve: refused non-private or unrecognized source")
                connection.cancel()
                return
            }
            Task { await self.handle(connection) }
        }
        try await awaitReady(listener)
        listener.stateUpdateHandler = { [weak self] state in
            if case let .failed(error) = state {
                Task { await self?.handleFailure(error) }
            }
        }
        self.listener = listener
        boundPort = listener.port?.rawValue
        isRunning = true
        // Hoisted locals: a member ref in the Logger autoclosure needs bare
        // `self.`, which swiftformat strips → build break (the logged landmine).
        let listeningPort = boundPort ?? 0
        let keyCount = credentials.count
        Self.log.notice("brain serve: listening on \(listeningPort) (\(keyCount) paired key(s))")
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        // ALL open connections die with the listener — revoke means the
        // revoked identity's idle/mid-handshake connections go too, not just
        // in-flight streams (audit S3, tightened by finding 6).
        for (_, connection) in openConnections {
            connection.cancel()
        }
        openConnections = [:]
        activeStreamConnections = [:]
        isRunning = false
        boundPort = nil
    }

    /// Local-preempts-remote (audit S2): a local turn cancels every in-flight
    /// remote stream — the client sees a clean stream interruption.
    public func cancelActiveGenerations() {
        for (_, connection) in activeStreamConnections {
            connection.cancel()
        }
        activeStreamConnections = [:]
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) async {
        let key = ObjectIdentifier(connection)
        guard openConnections.count < maxConnections else {
            Self.log.notice("brain serve: refused connection — at capacity")
            connection.cancel()
            return
        }
        openConnections[key] = connection
        defer { openConnections[key] = nil }
        // Passive impersonation signal (audit N2's log half): a TLS/PSK
        // handshake failure surfaces as .failed here — otherwise a probing
        // client dies in total silence. Error text only, never key material.
        connection.stateUpdateHandler = { state in
            if case let .failed(error) = state {
                Self.log.notice(
                    "brain serve: connection failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
        // Slowloris guard: a parseable request must arrive within the window.
        // Cancelled at parse, so a long-running SSE response is unaffected.
        let deadline = Task { [requestTimeout] in
            try? await Task.sleep(for: requestTimeout)
            if !Task.isCancelled {
                Self.log.notice("brain serve: dropped connection — no request within timeout")
                connection.cancel()
            }
        }
        defer { deadline.cancel() }
        var buffer = Data()
        while isRunning {
            guard let chunk = await receiveChunk(connection) else { break }
            buffer.append(chunk)
            guard let parsed = HTTPWireCodec.parseRequest(buffer) else {
                if buffer.count > 1_048_576 {
                    Self.log.notice("brain serve: dropped oversized request before parse")
                    break
                }
                continue
            }
            deadline.cancel()
            await respond(to: parsed.request, over: connection)
            break // Connection: close — one request per connection
        }
        connection.cancel()
    }

    private func respond(to request: HTTPRequest, over connection: NWConnection) async {
        switch BrainServeRoute.classify(method: request.method, path: request.path ?? "/") {
        case .generate:
            await serveGenerate(request, over: connection)
        case .health:
            let json = await handlers.healthJSON()
            _ = await send(BrainServeFrames.buffered(status: 200, reason: "OK", json: json), over: connection)
        case .mcp:
            guard let mcp = handlers.mcp else {
                _ = await send(notFound(reason: "mcp disabled on this listener"), over: connection)
                return
            }
            let response = await mcp(request)
            _ = await send(HTTPWireCodec.encode(response), over: connection)
        case .pair:
            guard let pair = handlers.pair else {
                _ = await send(notFound(reason: "pairing is not open"), over: connection)
                return
            }
            let json = await pair(PairRequest.parse(request.body))
            _ = await send(BrainServeFrames.buffered(status: 200, reason: "OK", json: json), over: connection)
        case .notFound:
            _ = await send(notFound(reason: "no such route"), over: connection)
        }
    }

    private func serveGenerate(_ request: HTTPRequest, over connection: NWConnection) async {
        guard let generateRequest = GenerateRequest.parse(request.body) else {
            _ = await send(
                BrainServeFrames.buffered(
                    status: 400, reason: "Bad Request", json: #"{"error":"prompt required"}"#
                ),
                over: connection
            )
            return
        }
        // Single-flight: the one MLX slot never serves two remote streams at
        // once (2026-08-19 audit, finding 4). Checked and claimed in one
        // synchronous actor stretch, so two arrivals can't both pass.
        let key = ObjectIdentifier(connection)
        guard activeStreamConnections.isEmpty else {
            if let frame = BrainServeFrames.busy(.busyRemote(retryAfterSeconds: 15)) {
                _ = await send(frame, over: connection)
            }
            return
        }
        activeStreamConnections[key] = connection
        defer { activeStreamConnections[key] = nil }

        if let refusal = await BrainServeFrames.busy(handlers.admit()) {
            _ = await send(refusal, over: connection)
            return
        }
        guard let stream = await handlers.generate(generateRequest) else {
            // Raw generation unavailable (façade's active backend can't do a
            // persona-free session) — an honest 503, never a persona-seeded
            // fallback and never an empty "success" stream.
            _ = await send(
                BrainServeFrames.buffered(
                    status: 503, reason: "Service Unavailable",
                    json: #"{"error":"raw generation unavailable"}"#
                ),
                over: connection
            )
            return
        }
        guard await send(BrainServeFrames.sseHead(), over: connection) else { return }
        for await token in stream {
            guard await send(BrainServeFrames.tokenEvent(token), over: connection) else {
                // Client hung up (or preemption cancelled us) — stop consuming
                // so the producer's stream sees the drop and unwinds.
                return
            }
        }
        _ = await send(BrainServeFrames.doneEvent(), over: connection)
    }

    private func notFound(reason: String) -> Data {
        BrainServeFrames.buffered(status: 404, reason: "Not Found", json: "{\"error\":\"\(reason)\"}")
    }

    // MARK: - NW plumbing (the LocalMCPHTTPServer shapes)

    private func awaitReady(_ listener: NWListener) async throws {
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

    private func handleFailure(_ error: NWError) {
        guard isRunning else { return }
        Self.log.error("brain serve listener failed: \(error.localizedDescription, privacy: .public)")
        stop()
        onAbnormalStop?("Brain serve listener failed: \(error.localizedDescription)")
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

    /// Send that reports delivery — false means the connection is gone, which
    /// is the SSE loop's stop signal.
    private func send(_ data: Data, over connection: NWConnection) async -> Bool {
        await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }
}
