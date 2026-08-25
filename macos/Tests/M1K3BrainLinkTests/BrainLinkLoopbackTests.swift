//
//  BrainLinkLoopbackTests.swift
//  M1K3BrainLinkTests
//
//  The client and server halves of Brain at Home, wired together for real:
//  BrainConnection dialing a live BrainServeListener over genuine TLS-PSK on
//  loopback (ephemeral ports). This is the same precedent as
//  BrainServeListenerTests, but exercising the PRODUCTION client transport
//  instead of a scratch exchange loop — pair, health, the SSE stream, the
//  etiquette refusals, and the wrong-key negative path.
//
//  Signed: Kev + claude-fable-5, 2026-08-24, Confidence 0.85 (real TLS-PSK
//  round-trips; LAN behaviour on hardware remains verify-owed).
//  Prior: BrainServeListenerTests (the loopback precedent).
//

import Foundation
import M1K3BrainLink
import M1K3BrainServe
import Testing

private let key = Data((0 ..< 32).map { UInt8($0 &+ 7) })
private let credential = PSKCredential(identity: "loopback-device", key: key)

private func startListener(
    admit: @escaping @Sendable () async -> RemoteTurnDecision = { .serve },
    generate: @escaping @Sendable (GenerateRequest) async -> AsyncStream<String>? = { _ in
        AsyncStream { continuation in
            for token in ["Hel", "lo ", "Kev"] {
                continuation.yield(token)
            }
            continuation.finish()
        }
    },
    health: @escaping @Sendable () async -> String = { #"{"ok":true,"brain":"Big","ready":true,"v":"1"}"# },
    pair: (@Sendable (PairRequest) async -> String)? = nil
) async throws -> (listener: BrainServeListener, port: UInt16) {
    let listener = BrainServeListener(
        port: 0,
        credentials: [credential],
        handlers: BrainServeHandlers(
            admit: admit, generate: generate, healthJSON: health, mcp: nil, pair: pair
        )
    )
    try await listener.start()
    let port = await listener.boundPort
    return try (listener, #require(port))
}

@Suite(.serialized)
struct BrainLinkLoopbackTests {
    @Test func healthRoundTripsOverTLSPSK() async throws {
        let (listener, port) = try await startListener()
        defer { Task { await listener.stop() } }
        let (head, body) = try await BrainConnection.request(
            BrainLinkFrames.get("/v1/health", host: "127.0.0.1"),
            host: "127.0.0.1", port: port, credential: credential
        )
        #expect(head.status == 200)
        let health = BrainHealth.parse(body)
        #expect(health == BrainHealth(ok: true, brain: "Big", ready: true))
        await listener.stop()
    }

    @Test func generateStreamsTokensToCompletion() async throws {
        let (listener, port) = try await startListener()
        defer { Task { await listener.stop() } }
        var assembled = ""
        let stream = BrainConnection.stream(
            BrainLinkFrames.post(
                "/v1/generate", host: "127.0.0.1",
                body: BrainLinkFrames.generateBody(prompt: "say hi", maxTokens: nil)
            ),
            host: "127.0.0.1", port: port, credential: credential
        )
        for try await token in stream {
            assembled += token
        }
        #expect(assembled == "Hello Kev")
        await listener.stop()
    }

    @Test func busyMacRefusesTheStreamWithEtiquette() async throws {
        let (listener, port) = try await startListener(admit: { .coolingDown(retryAfterSeconds: 120) })
        defer { Task { await listener.stop() } }
        let stream = BrainConnection.stream(
            BrainLinkFrames.post(
                "/v1/generate", host: "127.0.0.1",
                body: BrainLinkFrames.generateBody(prompt: "hi", maxTokens: nil)
            ),
            host: "127.0.0.1", port: port, credential: credential
        )
        await #expect(throws: BrainLinkError.refused(BrainRefusal(reason: .cooling, retryAfterSeconds: 120))) {
            for try await _ in stream {}
        }
        await listener.stop()
    }

    @Test func rawUnavailableSurfacesAs503() async throws {
        let (listener, port) = try await startListener(generate: { _ in nil })
        defer { Task { await listener.stop() } }
        let stream = BrainConnection.stream(
            BrainLinkFrames.post(
                "/v1/generate", host: "127.0.0.1",
                body: BrainLinkFrames.generateBody(prompt: "hi", maxTokens: nil)
            ),
            host: "127.0.0.1", port: port, credential: credential
        )
        var thrown: Error?
        do {
            for try await _ in stream {}
        } catch {
            thrown = error
        }
        guard case .unavailable = thrown as? BrainLinkError else {
            Issue.record("expected .unavailable, got \(String(describing: thrown))")
            await listener.stop()
            return
        }
        await listener.stop()
    }

    @Test func wrongKeyNeverCompletesTheHandshake() async throws {
        let (listener, port) = try await startListener()
        defer { Task { await listener.stop() } }
        let wrong = PSKCredential(identity: "loopback-device", key: Data(repeating: 9, count: 32))
        await #expect(throws: BrainLinkError.self) {
            _ = try await BrainConnection.request(
                BrainLinkFrames.get("/v1/health", host: "127.0.0.1"),
                host: "127.0.0.1", port: port, credential: wrong,
                timeout: .seconds(5)
            )
        }
        await listener.stop()
    }

    @Test func pairRequestReachesAPairingShapedListener() async throws {
        // The pairing listener's shape from BrainServeController.beginPairing:
        // pair handler live, generation refused.
        let (listener, port) = try await startListener(
            admit: { .busyLocal(retryAfterSeconds: 3600) },
            generate: { _ in nil },
            health: { #"{"pairing":true}"# },
            pair: { request in
                request.deviceName == "Kev’s iPad"
                    ? #"{"status":"pending-approval"}"#
                    : #"{"error":"wrong name"}"#
            }
        )
        defer { Task { await listener.stop() } }
        let (head, body) = try await BrainConnection.request(
            BrainLinkFrames.post(
                "/v1/pair", host: "127.0.0.1",
                body: BrainLinkFrames.pairBody(deviceName: "Kev’s iPad")
            ),
            host: "127.0.0.1", port: port, credential: credential
        )
        #expect(head.status == 200)
        #expect(PairResponse.parse(body) == .pendingApproval)
        await listener.stop()
    }
}
