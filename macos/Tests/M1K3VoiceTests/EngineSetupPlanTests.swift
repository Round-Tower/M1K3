//
//  EngineSetupPlanTests.swift
//  M1K3VoiceTests
//
//  What configureEngineIfNeeded must do, as pure data. Pins the two bugs from
//  the 2026-10-02 hang: a RUNNING engine that fails every render must be
//  rebuilt (not reused), and a player that is already attached must never be
//  attached a second time after `engineConfigured` is cleared.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-02, Confidence 0.85, Prior: Unknown

@testable import M1K3Voice
import Testing

struct EngineSetupPlanTests {
    private func plan(
        configured: Bool = true,
        rateMatches: Bool = true,
        running: Bool = true,
        attached: Bool = true,
        needsRebuild: Bool = false
    ) -> EngineSetupPlan {
        EngineSetupPlan.make(
            configured: configured, sampleRateMatches: rateMatches, engineRunning: running,
            playerAttached: attached, needsRebuild: needsRebuild
        )
    }

    @Test("a healthy configured running engine is reused untouched")
    func reuse() {
        #expect(plan().isNoOp)
    }

    @Test("a rebuild request tears down even though the engine is running")
    func rebuildBeatsRunning() {
        let result = plan(needsRebuild: true)
        #expect(!result.isNoOp)
        #expect(result.teardown)
        #expect(result.startEngine)
    }

    @Test("a rebuild keeps the player attached rather than attaching twice")
    func rebuildDoesNotReattach() {
        #expect(plan(needsRebuild: true).attachPlayer == false)
    }

    @Test("after a configuration change the player is still attached, so no second attach")
    func noDoubleAttach() {
        let result = plan(configured: false, running: false, attached: true)
        #expect(result.attachPlayer == false)
        #expect(result.startEngine)
    }

    @Test("first use attaches and starts")
    func firstUse() {
        let result = plan(configured: false, running: false, attached: false)
        #expect(result.attachPlayer)
        #expect(result.startEngine)
        #expect(result.disconnectPlayer == false)
    }

    @Test("a sample-rate change disconnects the old connection but keeps the engine running")
    func rateChange() {
        let result = plan(rateMatches: false)
        #expect(result.disconnectPlayer)
        #expect(result.startEngine == false)
        #expect(result.teardown == false)
    }

    @Test("a stopped engine restarts")
    func stoppedEngine() {
        #expect(plan(running: false).startEngine)
    }
}
