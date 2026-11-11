//
//  LocalAPIServer.swift
//  M1K3LocalAPI
//
//  The Local API's only effectful part: a loopback TCP listener that reads one
//  HTTP request per connection, hands it to `LocalAPIHandler`, and writes the
//  reply's pieces back as they come (so a streamed answer reaches the client
//  token by token). Everything it decides is decided in the handler and the
//  policies, which are tested; this shell is verify-by-launch with a real
//  client (curl, the OpenAI SDK).
//
//  Loopback pinned: the listener binds 127.0.0.1 only, so a connection from
//  another machine never arrives. A client that goes away mid-answer cancels
//  the generation.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-11, Confidence 0.65, Prior: none (new file).
//  The bind and read loop follow LocalMCPHTTPServer (2026-06-11), which has run
//  in the app since; streaming writes follow Brain at Home's listener.
//  Open: untried against a real client until the app wiring lands.
//

import Foundation
import M1K3LogCore
import Network
import os

public actor LocalAPIServer {
    /// Not 4242 (the MCP server) and not 4243 (Brain at Home): the first launch check found the clash.
    public static let defaultPort: UInt16 = 4141

    private static let log = Logger(subsystem: "app.m1k3", category: "local-api")

    public nonisolated let port: UInt16
    private let handler: LocalAPIHandler
    private let readDeadline: Double
    private let onAbnormalStop: (@Sendable (String) -> Void)?
    private var listener: NWListener?
    public private(set) var isRunning = false
    /// Connections being read or answered. Capped: a local process cannot pile up sockets here.
    private var openConnections = 0
    static let maxConnections = 8
    /// How long one write may stall before the connection is dropped (a client that stops reading).
    static let writeStallSeconds: Double = 60

    public init(
        port: UInt16 = LocalAPIServer.defaultPort, handler: LocalAPIHandler, readDeadline: Double = 30,
        onAbnormalStop: (@Sendable (String) -> Void)? = nil
    ) {
        self.port = port
        self.handler = handler
        self.readDeadline = readDeadline
        self.onAbnormalStop = onAbnormalStop
    }

    /// The person at the Mac has started using M1K3: a call in flight ends now.
    public func preempt() async {
        await handler.preempt()
    }

    /// Bind and serve until `stop()`. Returns only once the socket is really bound, so a port already in
    /// use is an error here and never a false "Running".
    public func start() async throws {
        guard !isRunning else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw LocalAPIServerError.invalidPort(port) }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            Task { await self.handle(connection) }
        }
        try await awaitReady(listener)
        listener.stateUpdateHandler = { [weak self] state in
            if case let .failed(error) = state {
                Task { await self?.failed(error) }
            }
        }
        self.listener = listener
        isRunning = true
        let bound = port // a local, so the log interpolation captures no actor state
        Self.log.notice("Local API listening on 127.0.0.1:\(bound, privacy: .public)")
    }

    public func stop() async {
        listener?.cancel()
        listener = nil
        isRunning = false
        await handler.preempt()
    }

    private func failed(_ error: NWError) async {
        guard isRunning else { return }
        Self.log.error("Local API listener failed: \(error.localizedDescription, privacy: .public)")
        await stop()
        onAbnormalStop?("The Local API stopped: \(error.localizedDescription)")
    }

    private func awaitReady(_ listener: NWListener) async throws {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let resumed = OSAllocatedUnfairLock(initialState: false)
                let resumeOnce: @Sendable (Result<Void, Error>) -> Void = { result in
                    let first = resumed.withLock { done -> Bool in
                        if done { return false }
                        done = true
                        return true
                    }
                    if first { continuation.resume(with: result) }
                }
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: resumeOnce(.success(()))
                    case let .failed(error), let .waiting(error): resumeOnce(.failure(error))
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

    // MARK: - One connection, one request

    private func handle(_ connection: NWConnection) async {
        guard openConnections < Self.maxConnections else {
            connection.cancel()
            return
        }
        openConnections += 1
        defer { openConnections -= 1 }
        connection.start(queue: .global(qos: .userInitiated))
        // A socket that never finishes its request must not hold this task: cancelling the
        // connection makes the pending receive return nil.
        let deadline = Task { [readDeadline] in
            try await Task.sleep(for: .seconds(readDeadline))
            guard !Task.isCancelled else { return }
            connection.cancel()
        }
        defer {
            deadline.cancel()
            connection.cancel()
        }
        var buffer = Data()
        var request: LocalAPIRequest?
        while isRunning, request == nil {
            guard let chunk = await receive(connection) else { return }
            buffer.append(chunk)
            if LocalAPIHTTP.headIsTooLarge(buffer) {
                let tooLarge = LocalAPIError(
                    status: 431, type: "invalid_request_error", code: nil, message: "The request headers are too large."
                )
                await send(LocalAPIWire.response(for: tooLarge), over: connection)
                return
            }
            if let declared = LocalAPIHTTP.declaredLength(buffer), declared > LocalAPIHTTP.maxBodyBytes {
                let tooLarge = LocalAPIError(
                    status: 413, type: "invalid_request_error", code: nil, message: "The request body is too large."
                )
                await send(LocalAPIWire.response(for: tooLarge), over: connection)
                return
            }
            guard buffer.count <= LocalAPIHTTP.maxBodyBytes + 65536 else { return }
            request = LocalAPIHTTP.parse(buffer)
        }
        guard let request else { return }
        deadline.cancel()

        // The client hanging up must stop the generation, during a long silent prefill and on a call
        // that writes nothing until the end too. Two signals, both armed BEFORE the reply is asked for:
        // the connection's state, and a read that only returns when the peer closes.
        let hangUp = HangUp()
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: hangUp.fire()
            default: break
            }
        }
        let watcher = Task {
            while await self.receive(connection) != nil {} // extra bytes are ignored: one request per connection
            hangUp.fire()
        }
        defer { watcher.cancel() }

        let reply = await handler.reply(to: request)
        let writer = Task {
            for await piece in reply.pieces {
                guard await self.send(piece, over: connection) else { return }
            }
        }
        hangUp.onFire { writer.cancel() }
        await withTaskCancellationHandler {
            await writer.value
        } onCancel: {
            writer.cancel()
        }
    }

    private func receive(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { data, _, _, error in
                if let data, !data.isEmpty, error == nil {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    /// False when the write failed (the client went away).
    @discardableResult
    private func send(_ data: Data, over connection: NWConnection) async -> Bool {
        // A client that stops reading must not hold a connection and its writer for ever.
        let stalled = Task {
            try await Task.sleep(for: .seconds(Self.writeStallSeconds))
            connection.cancel()
        }
        defer { stalled.cancel() }
        return await withCheckedContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }
}

/// One-shot "the client has gone": remembers a hang-up that arrives before anyone is listening for it.
private final class HangUp: Sendable {
    private let state = OSAllocatedUnfairLock<(fired: Bool, action: (@Sendable () -> Void)?)>(initialState: (false, nil))

    func fire() {
        let action = state.withLock { state -> (@Sendable () -> Void)? in
            state.fired = true
            defer { state.action = nil }
            return state.action
        }
        action?()
    }

    func onFire(_ action: @escaping @Sendable () -> Void) {
        let already = state.withLock { state -> Bool in
            if !state.fired { state.action = action }
            return state.fired
        }
        if already { action() }
    }
}

public enum LocalAPIServerError: Error, Sendable, Equatable {
    case invalidPort(UInt16)
}
