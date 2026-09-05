//
//  BrainServeListenerTests.swift
//  M1K3BrainServeTests
//
//  Real loopback round-trips over the TLS-PSK listener (the
//  LocalMCPHTTPServerTests precedent) — including the NEGATIVE paths that ARE
//  the security story: wrong PSK and plain TCP get zero application bytes.
//  Ephemeral ports throughout; every waiter resumes (signal OR timeout).
//

import Foundation
import M1K3BrainLink
@testable import M1K3BrainServe
import Network
import Testing

private let goodKey = Data((0 ..< 32).map { UInt8($0) })
private let credential = PSKCredential(identity: "test-identity", key: goodKey)

private func makeHandlers(
    admit: @escaping @Sendable () async -> RemoteTurnDecision = { .serve },
    tokens: [String] = ["Hel", "lo"]
) -> BrainServeHandlers {
    BrainServeHandlers(
        admit: admit,
        generate: { _ in
            AsyncStream { continuation in
                for token in tokens {
                    continuation.yield(token)
                }
                continuation.finish()
            }
        },
        healthJSON: { #"{"ok":true,"brain":"Test"}"# }
    )
}

/// One request → all response bytes until the server closes (or the timeout).
/// Timeout cancels the connection, which resolves the read loop — no waiter
/// is ever left parked (the logged TaskGroup-hang lesson).
private func exchange(
    port: UInt16, parameters: NWParameters, request: Data, timeout: TimeInterval = 6
) async -> Data {
    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var data = Data()
        var resumed = false
        /// Self-referential @Sendable receive loop (a nested func can't be
        /// Sendable, so the recursion goes through this slot).
        var receiveLoop: (@Sendable () -> Void)!
    }
    let box = Box()
    let connection = NWConnection(host: .ipv4(.loopback), port: .init(rawValue: port)!, using: parameters)
    let queue = DispatchQueue(label: "brainserve.test.client")

    return await withCheckedContinuation { continuation in
        let finish: @Sendable () -> Void = {
            box.lock.lock()
            let first = !box.resumed
            box.resumed = true
            let data = box.data
            box.lock.unlock()
            if first {
                connection.cancel()
                continuation.resume(returning: data)
            }
        }
        box.receiveLoop = {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 262_144) { data, _, isComplete, error in
                if let data {
                    box.lock.lock()
                    box.data.append(data)
                    box.lock.unlock()
                }
                if isComplete || error != nil {
                    finish()
                } else {
                    box.receiveLoop()
                }
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: request, completion: .contentProcessed { _ in })
                box.receiveLoop()
            case .failed, .cancelled:
                finish()
            case .waiting:
                // TLS refusal parks in .waiting (retry loop) — that IS the
                // negative-path outcome; don't sit out the retries.
                finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { finish() }
    }
}

private func post(_ path: String, body: String) -> Data {
    let bytes = Data(body.utf8)
    return Data("POST \(path) HTTP/1.1\r\nHost: x\r\nContent-Length: \(bytes.count)\r\n\r\n".utf8) + bytes
}

private func get(_ path: String) -> Data {
    Data("GET \(path) HTTP/1.1\r\nHost: x\r\n\r\n".utf8)
}

private func goodParams() -> NWParameters {
    NWParameters(tls: BrainServeTLS.options(credentials: [credential]))
}

struct BrainServeListenerTests {
    @Test("a paired client reads health over the PSK channel")
    func healthRoundTrip() async throws {
        let listener = BrainServeListener(port: 0, credentials: [credential], handlers: makeHandlers())
        try await listener.start()
        let port = try #require(await listener.boundPort)

        let response = String(decoding: await exchange(
            port: port, parameters: goodParams(), request: get("/v1/health")
        ), as: UTF8.self)
        #expect(response.contains("200 OK"))
        #expect(response.contains(#""ok":true"#))
        await listener.stop()
    }

    @Test("generate streams SSE frames and ends with the done event")
    func generateStreams() async throws {
        let listener = BrainServeListener(port: 0, credentials: [credential], handlers: makeHandlers())
        try await listener.start()
        let port = try #require(await listener.boundPort)

        let response = String(decoding: await exchange(
            port: port, parameters: goodParams(),
            request: post("/v1/generate", body: #"{"prompt":"hi"}"#)
        ), as: UTF8.self)
        #expect(response.contains("text/event-stream"))
        #expect(response.contains(#"data: {"token":"Hel"}"#))
        #expect(response.contains(#"data: {"token":"lo"}"#))
        #expect(response.contains("event: done"))
        await listener.stop()
    }

    @Test("a busy admit answers 429 + Retry-After instead of generating")
    func busyRefuses() async throws {
        let listener = BrainServeListener(
            port: 0, credentials: [credential],
            handlers: makeHandlers(admit: { .busyLocal(retryAfterSeconds: 15) })
        )
        try await listener.start()
        let port = try #require(await listener.boundPort)

        let response = String(decoding: await exchange(
            port: port, parameters: goodParams(),
            request: post("/v1/generate", body: #"{"prompt":"hi"}"#)
        ), as: UTF8.self)
        #expect(response.contains("429"))
        #expect(response.contains("Retry-After: 15"))
        #expect(!response.contains("event: done"))
        await listener.stop()
    }

    @Test("with two paired devices, the SECOND identity's key completes the handshake")
    func multiCredentialSecondIdentity() async throws {
        let second = PSKCredential(identity: "device-two", key: Data((32 ..< 64).map { UInt8($0) }))
        let listener = BrainServeListener(
            port: 0, credentials: [credential, second], handlers: makeHandlers()
        )
        try await listener.start()
        let port = try #require(await listener.boundPort)

        // A client presenting the SECOND device's identity + key must be served
        // (the multi-paired case the single-key tests don't cover).
        let response = String(decoding: await exchange(
            port: port, parameters: NWParameters(tls: BrainServeTLS.options(credentials: [second])),
            request: get("/v1/health")
        ), as: UTF8.self)
        #expect(response.contains("200 OK"))
        #expect(response.contains(#""ok":true"#))
        await listener.stop()
    }

    @Test("a second connection with an UNKNOWN identity is refused even right after a good one — no TLS session resumption")
    func noResumptionAcrossIdentities() async throws {
        // The iPad pairing bug (2026-09-05): round two's health poll to the SAME
        // host:port rode the resumed TLS session from round one, skipped the PSK
        // exchange, got 200, and the device adopted a never-approved key.
        let listener = BrainServeListener(port: 0, credentials: [credential], handlers: makeHandlers())
        try await listener.start()
        let port = try #require(await listener.boundPort)

        let first = String(decoding: await exchange(
            port: port, parameters: goodParams(), request: get("/v1/health")
        ), as: UTF8.self)
        #expect(first.contains("200 OK"))

        let stranger = PSKCredential(identity: "never-approved", key: credential.key)
        let second = await exchange(
            port: port, parameters: NWParameters(tls: BrainServeTLS.options(credentials: [stranger])),
            request: get("/v1/health")
        )
        #expect(!String(decoding: second, as: UTF8.self).contains("200 OK"))
        await listener.stop()
    }

    @Test("a wrong-PSK client gets ZERO bytes — the handshake never completes")
    func wrongPSKZeroBytes() async throws {
        let listener = BrainServeListener(port: 0, credentials: [credential], handlers: makeHandlers())
        try await listener.start()
        let port = try #require(await listener.boundPort)

        let wrong = PSKCredential(identity: "test-identity", key: Data(repeating: 0xFF, count: 32))
        let response = await exchange(
            port: port, parameters: NWParameters(tls: BrainServeTLS.options(credentials: [wrong])),
            request: get("/v1/health")
        )
        #expect(response.isEmpty)
        await listener.stop()
    }

    @Test("a plain-TCP client is served no application bytes — at most a TLS alert record")
    func plainTCPNoAppBytes() async throws {
        let listener = BrainServeListener(port: 0, credentials: [credential], handlers: makeHandlers())
        try await listener.start()
        let port = try #require(await listener.boundPort)

        let response = await exchange(port: port, parameters: .tcp, request: get("/v1/health"))
        // Empty, or TLS record framing only (0x15 alert / 0x16 handshake) —
        // never HTTP (audit B4's zero-application-bytes shape, spike-proven).
        #expect(response.isEmpty || [0x15, 0x16].contains(response[0]))
        #expect(!String(decoding: response, as: UTF8.self).contains("200 OK"))
        await listener.stop()
    }

    @Test("mcp and pair routes answer 404 when their handlers are absent")
    func disabledRoutes() async throws {
        let listener = BrainServeListener(port: 0, credentials: [credential], handlers: makeHandlers())
        try await listener.start()
        let port = try #require(await listener.boundPort)

        let mcp = String(decoding: await exchange(
            port: port, parameters: goodParams(), request: post("/mcp", body: "{}")
        ), as: UTF8.self)
        #expect(mcp.contains("404"))
        let pair = String(decoding: await exchange(
            port: port, parameters: goodParams(), request: post("/v1/pair", body: #"{"name":"x"}"#)
        ), as: UTF8.self)
        #expect(pair.contains("404"))
        await listener.stop()
    }

    @Test("starting with zero credentials refuses — an unauthenticated listener cannot exist")
    func noCredentialsRefuses() async {
        let listener = BrainServeListener(port: 0, credentials: [], handlers: makeHandlers())
        await #expect(throws: (any Error).self) {
            try await listener.start()
        }
    }

    @Test("a nil generate stream answers 503 — raw-unavailable is never an empty success")
    func rawUnavailable503() async throws {
        let handlers = BrainServeHandlers(
            admit: { .serve },
            generate: { _ in nil },
            healthJSON: { "{}" }
        )
        let listener = BrainServeListener(port: 0, credentials: [credential], handlers: handlers)
        try await listener.start()
        let port = try #require(await listener.boundPort)

        let response = String(decoding: await exchange(
            port: port, parameters: goodParams(),
            request: post("/v1/generate", body: #"{"prompt":"hi"}"#)
        ), as: UTF8.self)
        #expect(response.contains("503"))
        #expect(response.contains("raw generation unavailable"))
        #expect(!response.contains("event: done"))
        await listener.stop()
    }

    @Test("a second generate while one streams is refused 429 — the slot is single-flight")
    func secondGenerateRefused() async throws {
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let handlers = BrainServeHandlers(
            admit: { .serve },
            generate: { _ in
                AsyncStream { continuation in
                    continuation.yield("tok")
                    started.continuation.yield(())
                    Task {
                        var iterator = release.stream.makeAsyncIterator()
                        _ = await iterator.next()
                        continuation.finish()
                    }
                }
            },
            healthJSON: { "{}" }
        )
        let listener = BrainServeListener(port: 0, credentials: [credential], handlers: handlers)
        try await listener.start()
        let port = try #require(await listener.boundPort)

        let first = Task {
            await exchange(
                port: port, parameters: goodParams(),
                request: post("/v1/generate", body: #"{"prompt":"one"}"#), timeout: 10
            )
        }
        var startedIterator = started.stream.makeAsyncIterator()
        _ = await startedIterator.next() // the first stream is live

        let second = String(decoding: await exchange(
            port: port, parameters: goodParams(),
            request: post("/v1/generate", body: #"{"prompt":"two"}"#)
        ), as: UTF8.self)
        #expect(second.contains("429"))
        #expect(!second.contains("event: done"))

        release.continuation.yield(())
        let firstResponse = String(decoding: await first.value, as: UTF8.self)
        #expect(firstResponse.contains(#"data: {"token":"tok"}"#))
        #expect(firstResponse.contains("event: done"))
        await listener.stop()
    }

    @Test("a connection that never sends a request is dropped at the deadline — the Slowloris guard")
    func slowlorisDropped() async throws {
        let listener = BrainServeListener(
            port: 0, credentials: [credential], handlers: makeHandlers(),
            requestTimeout: .milliseconds(300)
        )
        try await listener.start()
        let port = try #require(await listener.boundPort)

        let clock = ContinuousClock()
        let start = clock.now
        // Plain TCP, nothing sent: the server's deadline (0.3s) must close it
        // long before the CLIENT's 6s fallback — elapsed time is the assert.
        let response = await exchange(port: port, parameters: .tcp, request: Data())
        #expect(response.isEmpty || [0x15, 0x16].contains(response[0]))
        #expect(clock.now - start < .seconds(4))
        await listener.stop()
    }
}

struct PrivateSourcePolicyTests {
    @Test("private, loopback, and link-local sources pass; public addresses don't")
    func ranges() {
        for host in ["127.0.0.1", "::1", "10.0.0.5", "172.16.9.9", "172.31.255.1",
                     "192.168.1.30", "169.254.10.10", "fe80::1%en0", "fd12::9"]
        {
            #expect(PrivateSourcePolicy.isPrivate(host: host), "\(host) should be private")
        }
        for host in ["8.8.8.8", "172.32.0.1", "193.168.1.1", "2a00:1450::1", "100.64.7.7"] {
            #expect(!PrivateSourcePolicy.isPrivate(host: host), "\(host) should be refused")
        }
    }

    @Test("IPv4-mapped IPv6 judges the EMBEDDED address; malformed strings fail closed")
    func mappedAndMalformed() {
        // Dual-stack accepts can render a v4 peer as ::ffff:a.b.c.d — a
        // private embedded address must not be refused (real LAN client),
        // and a public one must not slip through the IPv6 prefixes.
        #expect(PrivateSourcePolicy.isPrivate(host: "::ffff:192.168.1.5"))
        #expect(!PrivateSourcePolicy.isPrivate(host: "::ffff:8.8.8.8"))
        // Malformed octets fail CLOSED (2026-08-19 audit, note 10).
        #expect(!PrivateSourcePolicy.isPrivate(host: "192.168.1.999"))
        #expect(!PrivateSourcePolicy.isPrivate(host: "not-an-address"))
    }
}
