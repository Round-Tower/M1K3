//
//  PairingSessionTests.swift
//  M1K3BrainServeTests
//
//  The pairing ceremony's state machine — audit B2's "nothing commits until
//  Approve" pinned as behaviour.
//

import Foundation
@testable import M1K3BrainServe
import Testing

private let t0 = Date(timeIntervalSince1970: 1_786_800_000)

struct PairingSessionTests {
    @Test("the happy path: display → pair request → approve mints exactly one device")
    func happyPath() {
        var session = PairingSession()
        session.beginDisplay(identity: "id-1", now: t0)
        let requested = session.pairRequested(
            candidateName: "Kev's Pixel", identity: "id-1", now: t0.addingTimeInterval(10)
        )
        #expect(requested)
        let device = session.approve(now: t0.addingTimeInterval(12))
        #expect(device == PairedDevice(identity: "id-1", name: "Kev's Pixel", addedAt: t0.addingTimeInterval(12)))
        #expect(session.phase == .idle)
        // A second approve mints nothing — one candidate, one commit.
        #expect(session.approve(now: t0.addingTimeInterval(13)) == nil)
    }

    @Test("approve without a pair request mints nothing — the QR alone commits nothing")
    func approveNeedsRequest() {
        var session = PairingSession()
        session.beginDisplay(identity: "id-1", now: t0)
        #expect(session.approve(now: t0) == nil)
    }

    @Test("a pair request for the wrong identity, after expiry, or while idle is ignored")
    func rejectedRequests() {
        var session = PairingSession()
        let whileIdle = session.pairRequested(candidateName: "x", identity: "id-1", now: t0)
        #expect(!whileIdle) // idle

        session.beginDisplay(identity: "id-1", now: t0)
        let wrongIdentity = session.pairRequested(candidateName: "x", identity: "other", now: t0)
        #expect(!wrongIdentity) // wrong identity
        let expired = session.pairRequested(
            candidateName: "x", identity: "id-1",
            now: t0.addingTimeInterval(PairingSession.displayTTL + 1)
        )
        #expect(!expired) // expired
    }

    @Test("tick expires a displayed QR back to idle, exactly once")
    func expiry() {
        var session = PairingSession()
        session.beginDisplay(identity: "id-1", now: t0)
        let early = session.tick(now: t0.addingTimeInterval(30))
        #expect(!early)
        let atTTL = session.tick(now: t0.addingTimeInterval(PairingSession.displayTTL))
        #expect(atTTL)
        #expect(session.phase == .idle)
        let again = session.tick(now: t0.addingTimeInterval(120))
        #expect(!again) // already idle
    }

    @Test("awaitingApproval never expires by clock — a human is mid-decision")
    func approvalHolds() {
        var session = PairingSession()
        session.beginDisplay(identity: "id-1", now: t0)
        session.pairRequested(candidateName: "Pixel", identity: "id-1", now: t0)
        let ticked = session.tick(now: t0.addingTimeInterval(3600))
        #expect(!ticked)
        #expect(session.phase == .awaitingApproval(candidateName: "Pixel", identity: "id-1"))
    }

    @Test("cancel discards the candidate from any phase")
    func cancelDiscards() {
        var session = PairingSession()
        session.beginDisplay(identity: "id-1", now: t0)
        session.pairRequested(candidateName: "Pixel", identity: "id-1", now: t0)
        session.cancel()
        #expect(session.phase == .idle)
        #expect(session.approve(now: t0) == nil)
    }

    @Test("a blank candidate name renders as \"A device\", never an empty label")
    func blankName() {
        var session = PairingSession()
        session.beginDisplay(identity: "id-1", now: t0)
        session.pairRequested(candidateName: "   ", identity: "id-1", now: t0)
        #expect(session.phase == .awaitingApproval(candidateName: "A device", identity: "id-1"))
    }

    @Test("a re-display never clobbers a candidate awaiting Approve — decide or cancel first")
    func redisplayRefusedWhileAwaitingApproval() {
        var session = PairingSession()
        session.beginDisplay(identity: "id-1", now: t0)
        session.pairRequested(candidateName: "Pixel", identity: "id-1", now: t0)
        let redisplayed = session.beginDisplay(identity: "id-2", now: t0)
        #expect(!redisplayed)
        #expect(session.phase == .awaitingApproval(candidateName: "Pixel", identity: "id-1"))
        // The pending decision still resolves normally.
        let approved = session.approve(now: t0)
        #expect(approved?.identity == "id-1")
        // And once idle, a fresh display works again.
        let freshDisplay = session.beginDisplay(identity: "id-2", now: t0)
        #expect(freshDisplay)
    }
}
