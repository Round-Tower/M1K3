//
//  InterimBrainPolicyTests.swift
//  M1K3InferenceTests
//
//  The download gate should not be a wall when Mini can hold the fort: while a
//  weight-backed brain (Lil/Big) is still downloading/warming AND Apple
//  Foundation Models is available, chat stays open on Mini instead of blocking
//  behind the full-surface ModelGateView. Everything else keeps today's gate.
//
//  Signed: Kev + claude-fable-5, 2026-07-25, Confidence 0.9, Prior: Unknown
//

@testable import M1K3Inference
import Testing

struct InterimBrainPolicyTests {
    // MARK: - Open

    @Test("ready readiness is open regardless of AFM")
    func readyIsOpen() {
        #expect(InterimBrainPolicy.gate(
            readiness: .ready, selectedRequiresWeights: true, afm: .blocked(userFixable: false)
        ) == .open)
        #expect(InterimBrainPolicy.gate(
            readiness: .ready, selectedRequiresWeights: false, afm: .available
        ) == .open)
    }

    // MARK: - The interim bridge (the point of the policy)

    @Test("weight-backed brain downloading with AFM available bridges to interim")
    func downloadingWithAFMBridges() {
        #expect(InterimBrainPolicy.gate(
            readiness: .loading(.downloading(fraction: 0.4)), selectedRequiresWeights: true, afm: .available
        ) == .interim)
    }

    @Test("interim holds through the post-download Metal load (.preparing)")
    func preparingStillBridges() {
        #expect(InterimBrainPolicy.gate(
            readiness: .loading(.preparing), selectedRequiresWeights: true, afm: .available
        ) == .interim)
    }

    // MARK: - Blocked (every other direction keeps today's wall)

    @Test("downloading without AFM stays blocked")
    func downloadingWithoutAFMBlocks() {
        #expect(InterimBrainPolicy.gate(
            readiness: .loading(.downloading(fraction: 0.4)), selectedRequiresWeights: true,
            afm: .blocked(userFixable: true)
        ) == .blocked)
    }

    @Test("AFM merely warming (.notReady) does not bridge — nothing can serve yet")
    func afmNotReadyBlocks() {
        #expect(InterimBrainPolicy.gate(
            readiness: .loading(.downloading(fraction: 0.4)), selectedRequiresWeights: true, afm: .notReady
        ) == .blocked)
    }

    @Test("an instant backend loading never bridges to itself")
    func instantBackendLoadingBlocks() {
        // selectedRequiresWeights == false means Mini IS the selected brain —
        // routing its own loading state "to Mini" would be circular.
        #expect(InterimBrainPolicy.gate(
            readiness: .loading(.preparing), selectedRequiresWeights: false, afm: .available
        ) == .blocked)
    }

    @Test("failed load keeps the gate — retry needs its surface")
    func failedBlocks() {
        #expect(InterimBrainPolicy.gate(
            readiness: .failed("boom"), selectedRequiresWeights: true, afm: .available
        ) == .blocked)
    }

    @Test("unavailable backend keeps the gate — the rescue buttons live there")
    func unavailableBlocks() {
        #expect(InterimBrainPolicy.gate(
            readiness: .unavailable, selectedRequiresWeights: false, afm: .available
        ) == .blocked)
    }

    // MARK: - Turn-taking convenience

    @Test("canTakeTurn is true for open and interim, false for blocked")
    func canTakeTurn() {
        #expect(ChatGate.open.canTakeTurn)
        #expect(ChatGate.interim.canTakeTurn)
        #expect(!ChatGate.blocked.canTakeTurn)
    }
}
