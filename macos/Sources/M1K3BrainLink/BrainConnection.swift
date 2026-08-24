//
//  BrainConnection.swift
//  M1K3BrainLink
//
//  The client transport: one HTTP request/response (or one SSE stream) over
//  a fresh TLS-PSK NWConnection — URLSession has no external-PSK hook
//  (spike A2), so the wire is hand-fed through the pure codecs in
//  BrainLinkWire. One request per connection mirrors the server's
//  Connection: close contract.
//
//  Concurrency shape: NWConnection callbacks arrive on their own queue; a
//  lock-boxed once-resume bridges them into async/await (the proven
//  BrainServeListenerTests client shape — every waiter resumes on signal OR
//  timeout, never parks).
//
//  Verified by real loopback TLS-PSK round-trips against BrainServeListener
//  in BrainLinkLoopbackTests; live-LAN behaviour is verify-by-launch
//  (hardware-owed, the Phase C iPad ceremony).
//
//  Signed: Kev + claude-fable-5, 2026-08-24, Confidence 0.8 (transport is
//  loopback-tested against the real server; the deadline/idle plumbing is
//  test-pinned; real-LAN and cellular-interface behaviour are named
//  verify-owed). Prior: Tests/M1K3BrainServeTests/BrainServeListenerTests
//  (the exchange() client shape).
//

import Foundation
import Network
import os

public enum BrainLinkError: Error, Sendable, Equatable {
    /// Couldn't connect or complete the TLS-PSK handshake — wrong network,
    /// Mac asleep, service off, or this device was revoked.
    case unreachable(String)
    /// The Mac answered 429 — busy/cooling/warming etiquette.
    case refused(BrainRefusal)
    /// The Mac answered 503 — raw generation unavailable on the active brain.
    case unavailable(String)
    case badResponse(String)
    case timedOut
    /// The SSE stream broke mid-generation (hangup, preemption, error event).
    case streamInterrupted(String)
}

public enum BrainConnection {
    /// One buffered request/response. The returned body is complete per the
    /// server's Content-Length (or connection close when it sends none).
    public static func request(
        _ requestBytes: Data,
        host: String,
        port: UInt16,
        credential: PSKCredential,
        timeout: Duration = .seconds(10)
    ) async throws -> (head: HTTPResponseHead, body: Data) {
        let connection = try await connect(host: host, port: port, credential: credential, timeout: timeout)
        defer { connection.cancel() }
        try await send(requestBytes, over: connection)
        let watchdog = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { connection.cancel() }
        }
        defer { watchdog.cancel() }
        var buffer = Data()
        var parsedHead: (head: HTTPResponseHead, bodyStart: Int)?
        for await chunk in chunkStream(connection) {
            buffer.append(chunk)
            if parsedHead == nil {
                parsedHead = HTTPResponseParser.parseHead(buffer)
            }
            if let parsed = parsedHead, let length = parsed.head.contentLength,
               buffer.count - parsed.bodyStart >= length
            {
                let body = buffer.subdata(in: parsed.bodyStart ..< parsed.bodyStart + length)
                return (parsed.head, body)
            }
        }
        // Connection closed. With a head and no Content-Length, what arrived
        // IS the body; otherwise the exchange died early.
        if let parsed = parsedHead {
            return (parsed.head, buffer.suffix(from: parsed.bodyStart))
        }
        throw BrainLinkError.timedOut
    }

    /// A /v1/generate exchange: yields tokens as the Mac streams them,
    /// finishes on the server's done event, throws refusals and stream
    /// breaks. `idleTimeout` bounds the gap BETWEEN chunks, not the whole
    /// generation — a long think keeps the stream alive by streaming.
    public static func stream(
        _ requestBytes: Data,
        host: String,
        port: UInt16,
        credential: PSKCredential,
        connectTimeout: Duration = .seconds(10),
        idleTimeout: Duration = .seconds(180)
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let connection = try await connect(
                        host: host, port: port, credential: credential, timeout: connectTimeout
                    )
                    defer { connection.cancel() }
                    try await send(requestBytes, over: connection)

                    let idle = IdleWatchdog(timeout: idleTimeout) { connection.cancel() }
                    defer { idle.stop() }

                    var buffer = Data()
                    var head: HTTPResponseHead?
                    var bodyStart = 0
                    var sse = SSEParser()
                    var finishedCleanly = false

                    readLoop: for await chunk in chunkStream(connection) {
                        idle.kick()
                        if head == nil {
                            buffer.append(chunk)
                            guard let parsed = HTTPResponseParser.parseHead(buffer) else { continue }
                            head = parsed.head
                            bodyStart = parsed.bodyStart
                            guard parsed.head.isEventStream else { continue } // buffered error body follows
                            for event in sse.feed(buffer.suffix(from: bodyStart)) {
                                if try handle(event, continuation: continuation) { finishedCleanly = true }
                            }
                            if finishedCleanly { break readLoop }
                            continue
                        }
                        guard let currentHead = head else { continue }
                        if currentHead.isEventStream {
                            for event in sse.feed(chunk) {
                                if try handle(event, continuation: continuation) { finishedCleanly = true }
                            }
                            if finishedCleanly { break readLoop }
                        } else {
                            buffer.append(chunk)
                        }
                    }
                    if finishedCleanly {
                        continuation.finish()
                        return
                    }
                    // Stream ended without a done event.
                    guard let finalHead = head else {
                        throw idle.fired ? BrainLinkError.timedOut : BrainLinkError.unreachable("connection lost")
                    }
                    if finalHead.isEventStream {
                        throw idle.fired
                            ? BrainLinkError.timedOut
                            : BrainLinkError.streamInterrupted("the Mac ended the stream early")
                    }
                    let body = buffer.suffix(from: bodyStart)
                    if let refusal = BrainRefusal.parse(
                        status: finalHead.status, body: body, retryAfterHeader: finalHead.retryAfterSeconds
                    ) {
                        throw BrainLinkError.refused(refusal)
                    }
                    if finalHead.status == 503 {
                        throw BrainLinkError.unavailable(errorMessage(from: body))
                    }
                    throw BrainLinkError.badResponse("HTTP \(finalHead.status): \(errorMessage(from: body))")
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Returns true when the stream finished cleanly (done event).
    private static func handle(
        _ event: SSEParser.Event, continuation: AsyncThrowingStream<String, Error>.Continuation
    ) throws -> Bool {
        switch event {
        case let .token(token):
            continuation.yield(token)
            return false
        case .done:
            return true
        case let .error(message):
            throw BrainLinkError.streamInterrupted(message)
        }
    }

    private static func errorMessage(from body: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let message = json["error"] as? String
        else { return "unexpected reply" }
        return message
    }

    // MARK: - NW plumbing

    static func connect(
        host: String, port: UInt16, credential: PSKCredential, timeout: Duration
    ) async throws -> NWConnection {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw BrainLinkError.unreachable("invalid port \(port)")
        }
        let parameters = NWParameters(tls: BrainServeTLS.options(credentials: [credential]))
        // A LAN brain is never on the cell network — refusing here keeps a
        // misconfigured address from burning data (mirrors the server's pin).
        parameters.prohibitedInterfaceTypes = [.cellular]
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)

        final class OnceBox: @unchecked Sendable {
            let lock = NSLock()
            var resumed = false
            func first() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if resumed { return false }
                resumed = true
                return true
            }
        }
        let once = OnceBox()
        return try await withCheckedThrowingContinuation { continuation in
            let deadline = Task {
                try? await Task.sleep(for: timeout)
                if !Task.isCancelled, once.first() {
                    connection.cancel()
                    continuation.resume(throwing: BrainLinkError.timedOut)
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.first() {
                        deadline.cancel()
                        continuation.resume(returning: connection)
                    }
                case let .failed(error):
                    if once.first() {
                        deadline.cancel()
                        connection.cancel()
                        continuation.resume(throwing: BrainLinkError.unreachable(error.localizedDescription))
                    }
                default:
                    // .waiting can recover (Wi-Fi wake) — the deadline bounds it.
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private static func send(_ data: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: BrainLinkError.unreachable(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private static func chunkStream(_ connection: NWConnection) -> AsyncStream<Data> {
        AsyncStream { continuation in
            final class LoopBox: @unchecked Sendable {
                var run: (@Sendable () -> Void)!
            }
            let box = LoopBox()
            box.run = {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        continuation.yield(data)
                    }
                    if isComplete || error != nil {
                        continuation.finish()
                    } else {
                        box.run()
                    }
                }
            }
            continuation.onTermination = { _ in connection.cancel() }
            box.run()
        }
    }
}

/// Kickable idle deadline: fires `onFire` if no kick lands within `timeout`.
/// Lock-boxed (not an actor) because kick() is called from a tight receive
/// loop and must not suspend.
final class IdleWatchdog: Sendable {
    private struct State {
        var generation = 0
        var stopped = false
        var fired = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let timeout: Duration
    private let onFire: @Sendable () -> Void

    var fired: Bool {
        state.withLock(\.fired)
    }

    init(timeout: Duration, onFire: @escaping @Sendable () -> Void) {
        self.timeout = timeout
        self.onFire = onFire
        kick()
    }

    func kick() {
        let expected: Int? = state.withLock { state in
            guard !state.stopped else { return nil }
            state.generation += 1
            return state.generation
        }
        guard let expected else { return }
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: timeout)
            let shouldFire = state.withLock { state in
                let firing = !state.stopped && state.generation == expected && !state.fired
                if firing { state.fired = true }
                return firing
            }
            if shouldFire { onFire() }
        }
    }

    func stop() {
        state.withLock { $0.stopped = true }
    }
}
