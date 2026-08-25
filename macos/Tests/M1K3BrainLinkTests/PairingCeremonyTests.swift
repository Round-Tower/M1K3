//
//  PairingCeremonyTests.swift
//  M1K3BrainLinkTests
//
//  The client-side pairing flow against a scripted transport: contact the
//  pairing listener, read the pending-approval reply, then poll the MAIN
//  port until the handshake with the freshly-minted credential succeeds —
//  the spec's "the device's next /v1/health succeeding IS the paired
//  signal" (§4). Failures are messages, never hangs.
//
//  Signed: Kev + claude-fable-5, 2026-08-24, Confidence 0.9 (pure flow over
//  an injected transport, TDD'd red-first). Prior: BRAIN_AT_HOME_SPEC §4.
//

import Foundation
import M1K3BrainLink
import os
import Testing

private let key = Data((0 ..< 32).map { UInt8($0) })

private func payload(hosts: [String] = ["192.168.1.24"]) -> PairingPayload {
    PairingPayload(
        psk: key, identity: "ID-1", pairingPort: 50001, mainPort: 4243,
        macName: "Studio", hosts: hosts
    )
}

/// Scripted transport: each call pops the next result for (host, port).
private final class ScriptedTransport: Sendable {
    private struct Entry {
        let host: String
        let port: UInt16
        let result: Result<(Int, Data), BrainLinkError>
    }

    private let script: OSAllocatedUnfairLock<[Entry]>

    init(_ script: [(host: String, port: UInt16, result: Result<(Int, Data), BrainLinkError>)]) {
        self.script = OSAllocatedUnfairLock(
            initialState: script.map { Entry(host: $0.host, port: $0.port, result: $0.result) }
        )
    }

    func transport() -> PairingCeremony<ContinuousClock>.Transport {
        { [script] _, host, port, _ in
            let entry: Entry? = script.withLock { entries in
                guard let index = entries.firstIndex(where: { $0.host == host && $0.port == port })
                else { return nil }
                return entries.remove(at: index)
            }
            guard let entry else { throw BrainLinkError.unreachable("no script for \(host):\(port)") }
            switch entry.result {
            case let .success((status, body)):
                let head = HTTPResponseParser.parseHead(
                    Data("HTTP/1.1 \(status) X\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body
                )!.head
                return (head, body)
            case let .failure(error):
                throw error
            }
        }
    }
}

struct PairingCeremonyTests {
    @Test func happyPathPairsAfterApprovalPollSucceeds() async {
        let pending = Data(#"{"status":"pending-approval"}"#.utf8)
        let health = Data(#"{"ok":true,"brain":"Big","ready":true,"v":"1"}"#.utf8)
        let scripted = ScriptedTransport([
            ("192.168.1.24", 50001, .success((200, pending))),
            // First two health polls: the human hasn't clicked Approve yet —
            // the main listener refuses the handshake.
            ("192.168.1.24", 4243, .failure(.unreachable("handshake"))),
            ("192.168.1.24", 4243, .failure(.unreachable("handshake"))),
            ("192.168.1.24", 4243, .success((200, health))),
        ])
        let ceremony = PairingCeremony(
            transport: scripted.transport(), pollInterval: .milliseconds(1), approvalWindow: .seconds(5)
        )
        let outcome = await ceremony.pair(payload: payload(), deviceName: "iPad")
        guard case let .paired(brain, brainHealth) = outcome else {
            Issue.record("expected paired, got \(outcome)")
            return
        }
        #expect(brain.identity == "ID-1")
        #expect(brain.name == "Studio")
        #expect(brain.hosts == ["192.168.1.24"])
        #expect(brain.lastKnownHost == "192.168.1.24")
        #expect(brainHealth.brain == "Big")
    }

    @Test func secondHostIsTriedWhenTheFirstIsUnreachable() async {
        let pending = Data(#"{"status":"pending-approval"}"#.utf8)
        let health = Data(#"{"ok":true,"brain":"Lil","ready":true,"v":"1"}"#.utf8)
        let scripted = ScriptedTransport([
            ("10.0.0.9", 50001, .failure(.timedOut)),
            ("192.168.1.24", 50001, .success((200, pending))),
            ("192.168.1.24", 4243, .success((200, health))),
        ])
        let ceremony = PairingCeremony(
            transport: scripted.transport(), pollInterval: .milliseconds(1), approvalWindow: .seconds(5)
        )
        let outcome = await ceremony.pair(
            payload: payload(hosts: ["10.0.0.9", "192.168.1.24"]), deviceName: "iPad"
        )
        guard case let .paired(brain, _) = outcome else {
            Issue.record("expected paired, got \(outcome)")
            return
        }
        #expect(brain.lastKnownHost == "192.168.1.24")
    }

    @Test func macRejectionSurfacesItsMessage() async {
        let rejected = Data(#"{"error":"pairing expired — regenerate the code on the Mac"}"#.utf8)
        let scripted = ScriptedTransport([
            ("192.168.1.24", 50001, .success((200, rejected))),
        ])
        let ceremony = PairingCeremony(
            transport: scripted.transport(), pollInterval: .milliseconds(1), approvalWindow: .seconds(1)
        )
        let outcome = await ceremony.pair(payload: payload(), deviceName: "iPad")
        #expect(outcome == .failed("pairing expired — regenerate the code on the Mac"))
    }

    @Test func noHostsFailsWithGuidanceNotAHang() async {
        let ceremony = PairingCeremony(
            transport: ScriptedTransport([]).transport(),
            pollInterval: .milliseconds(1), approvalWindow: .seconds(1)
        )
        let outcome = await ceremony.pair(payload: payload(hosts: []), deviceName: "iPad")
        guard case let .failed(message) = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
        #expect(message.contains("address"))
    }

    @Test func approvalWindowExpiryFailsCleanly() async {
        let pending = Data(#"{"status":"pending-approval"}"#.utf8)
        // Pair succeeds; every health poll fails — the human never clicks.
        var script: [(String, UInt16, Result<(Int, Data), BrainLinkError>)] = [
            ("192.168.1.24", 50001, .success((200, pending))),
        ]
        for _ in 0 ..< 200 {
            script.append(("192.168.1.24", 4243, .failure(.unreachable("handshake"))))
        }
        let ceremony = PairingCeremony(
            transport: ScriptedTransport(script).transport(),
            pollInterval: .milliseconds(1), approvalWindow: .milliseconds(50)
        )
        let outcome = await ceremony.pair(payload: payload(), deviceName: "iPad")
        guard case let .failed(message) = outcome else {
            Issue.record("expected failed, got \(outcome)")
            return
        }
        #expect(message.lowercased().contains("approve"))
    }
}
