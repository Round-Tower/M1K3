//
//  BrainLinkPolicyTests.swift
//  M1K3BrainLinkTests
//
//  The pure decision layers around the wire: which of the Mac's addresses
//  belong in a pairing QR, and how the client reads health, refusal, and
//  pair responses. Refusal/health payloads are pinned against the server's
//  own encoders where they exist.
//
//  Signed: Kev + claude-fable-5, 2026-08-24, Confidence 0.9 (pure, TDD'd
//  red-first). Prior: Unknown.
//

import Foundation
import M1K3BrainLink
import M1K3BrainServe
import Testing

struct LANAddressesTests {
    @Test func keepsPrivateIPv4AndDropsLoopbackAndLinkLocal() {
        let picked = LANAddresses.servable(from: [
            (interface: "lo0", address: "127.0.0.1"),
            (interface: "en0", address: "192.168.1.24"),
            (interface: "en0", address: "169.254.11.2"),
            (interface: "en1", address: "10.0.0.7"),
        ])
        #expect(picked == ["192.168.1.24", "10.0.0.7"])
    }

    @Test func dropsPublicAddresses() {
        let picked = LANAddresses.servable(from: [
            (interface: "en0", address: "8.8.8.8"),
            (interface: "en0", address: "192.168.1.24"),
        ])
        #expect(picked == ["192.168.1.24"])
    }

    @Test func dropsTunnelAndAirdropInterfacesEvenWithPrivateAddresses() {
        let picked = LANAddresses.servable(from: [
            (interface: "utun4", address: "10.99.0.2"),
            (interface: "awdl0", address: "fe80::abcd"),
            (interface: "llw0", address: "fe80::1"),
            (interface: "en0", address: "192.168.1.24"),
        ])
        #expect(picked == ["192.168.1.24"])
    }

    @Test func keepsUniqueLocalIPv6ButDropsLinkLocalIPv6() {
        let picked = LANAddresses.servable(from: [
            (interface: "en0", address: "fe80::1c2a%en0"),
            (interface: "en0", address: "fd00:abcd::5"),
            (interface: "en0", address: "192.168.1.24"),
        ])
        #expect(picked == ["192.168.1.24", "fd00:abcd::5"])
    }

    @Test func ipv4SortsAheadOfIPv6AndDuplicatesCollapse() {
        let picked = LANAddresses.servable(from: [
            (interface: "en0", address: "fd00::5"),
            (interface: "en0", address: "192.168.1.24"),
            (interface: "en1", address: "192.168.1.24"),
        ])
        #expect(picked == ["192.168.1.24", "fd00::5"])
    }
}

struct BrainHealthTests {
    @Test func parsesTheServersHealthShape() {
        // BrainServeController.healthJSON()'s exact shape.
        let body = Data(#"{"ok":true,"brain":"Big","ready":true,"v":"1"}"#.utf8)
        let health = BrainHealth.parse(body)
        #expect(health == BrainHealth(ok: true, brain: "Big", ready: true))
    }

    @Test func parsesNotReady() {
        let health = BrainHealth.parse(Data(#"{"ok":true,"brain":"Lil","ready":false,"v":"1"}"#.utf8))
        #expect(health?.ready == false)
    }

    @Test func junkReturnsNil() {
        #expect(BrainHealth.parse(Data("nope".utf8)) == nil)
        #expect(BrainHealth.parse(nil) == nil)
    }
}

struct BrainRefusalTests {
    private func headAndBody(_ wire: Data) -> (HTTPResponseHead, Data) {
        let parsed = HTTPResponseParser.parseHead(wire)!
        return (parsed.head, wire.suffix(from: parsed.bodyStart))
    }

    @Test func readsTheServersBusyFrame() throws {
        let (head, body) = try headAndBody(#require(BrainServeFrames.busy(.busyLocal(retryAfterSeconds: 15))))
        let refusal = BrainRefusal.parse(status: head.status, body: body, retryAfterHeader: head.retryAfterSeconds)
        #expect(refusal == BrainRefusal(reason: .busy, retryAfterSeconds: 15))
    }

    @Test func readsCoolingAndWarming() throws {
        let cooling = try headAndBody(#require(BrainServeFrames.busy(.coolingDown(retryAfterSeconds: 120))))
        #expect(
            BrainRefusal.parse(status: cooling.0.status, body: cooling.1, retryAfterHeader: cooling.0.retryAfterSeconds)?
                .reason == .cooling
        )
        let warming = try headAndBody(#require(BrainServeFrames.busy(.warmingUp(retryAfterSeconds: 30))))
        #expect(
            BrainRefusal.parse(status: warming.0.status, body: warming.1, retryAfterHeader: warming.0.retryAfterSeconds)?
                .reason == .warming
        )
    }

    @Test func non429IsNotARefusal() {
        #expect(BrainRefusal.parse(status: 200, body: Data(), retryAfterHeader: nil) == nil)
    }

    @Test func eachReasonHasFriendlyCopy() {
        for reason in [BrainRefusal.Reason.busy, .cooling, .warming] {
            let copy = BrainRefusal(reason: reason, retryAfterSeconds: 15).userMessage
            #expect(!copy.isEmpty)
        }
    }
}

struct PairResponseTests {
    @Test func pendingApprovalParses() {
        let body = Data(#"{"status":"pending-approval"}"#.utf8)
        #expect(PairResponse.parse(body) == .pendingApproval)
    }

    @Test func serverRejectionCarriesItsMessage() {
        let body = Data(#"{"error":"pairing expired — regenerate the code on the Mac"}"#.utf8)
        #expect(PairResponse.parse(body) == .rejected("pairing expired — regenerate the code on the Mac"))
    }

    @Test func junkIsARejectionNotACrash() {
        if case .rejected = PairResponse.parse(Data("???".utf8)) {} else {
            Issue.record("junk should reject")
        }
    }
}
