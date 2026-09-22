//
//  CoolHeadPolicyTests.swift
//  M1K3LanguageModelTests
//
//  Cool Head: under system thermal/power pressure, M1K3 caps EFFORT (agent
//  iterations, background work) and keeps the user's chosen brain — it never
//  silently demotes "Lil" to the weaker AFM (that's an identity + a full model
//  reload that would dump the KV/persona caches and partly defeat the thermal
//  goal). The decision is pure here; the ProcessInfo reads + the maxIterations
//  wiring are verify-by-launch.
//

import Foundation
@testable import M1K3LanguageModel
import Testing

struct CoolHeadPolicyTests {
    // MARK: - target: raw pressure → level

    @Test("a cool machine runs at full effort")
    func nominalIsFull() {
        #expect(CoolHeadPolicy.target(thermal: .nominal, lowPower: false) == .full)
        #expect(CoolHeadPolicy.target(thermal: .fair, lowPower: false) == .full)
    }

    @Test("serious thermal pressure eases effort")
    func seriousEases() {
        #expect(CoolHeadPolicy.target(thermal: .serious, lowPower: false) == .eased)
    }

    @Test("low-power mode eases even on a fair machine (battery is pressure too)")
    func lowPowerEases() {
        #expect(CoolHeadPolicy.target(thermal: .fair, lowPower: true) == .eased)
        #expect(CoolHeadPolicy.target(thermal: .nominal, lowPower: true) == .eased)
    }

    @Test("critical thermal pressure drops to minimal")
    func criticalIsMinimal() {
        #expect(CoolHeadPolicy.target(thermal: .critical, lowPower: false) == .minimal)
        // Critical dominates low-power.
        #expect(CoolHeadPolicy.target(thermal: .critical, lowPower: true) == .minimal)
    }

    // MARK: - hysteresis: degrade now, recover only after a dwell streak

    @Test("effort degrades IMMEDIATELY when pressure rises (no dwell on the way down)")
    func degradesImmediately() {
        let next = CoolHeadPolicy.next(.init(level: .full, recoverStreak: 0), target: .eased, minRecoveryTurns: 2)
        #expect(next == CoolHeadState(level: .eased, recoverStreak: 0))
        // And can drop further immediately.
        let deeper = CoolHeadPolicy.next(.init(level: .eased, recoverStreak: 1), target: .minimal, minRecoveryTurns: 2)
        #expect(deeper == CoolHeadState(level: .minimal, recoverStreak: 0))
    }

    @Test("recovery is gated — it does NOT happen until the relief streak is met")
    func recoveryGatedByDwell() {
        // Turn 1 of relief: hold eased, build the streak.
        let relief1 = CoolHeadPolicy.next(.init(level: .eased, recoverStreak: 0), target: .full, minRecoveryTurns: 2)
        #expect(relief1 == CoolHeadState(level: .eased, recoverStreak: 1))
        // Turn 2 of sustained relief: now recover.
        let relief2 = CoolHeadPolicy.next(relief1, target: .full, minRecoveryTurns: 2)
        #expect(relief2 == CoolHeadState(level: .full, recoverStreak: 0))
    }

    @Test("a pressure blip RESETS the relief streak — anti-flap")
    func blipResetsStreak() {
        // Building a relief streak at eased…
        let building = CoolHeadState(level: .eased, recoverStreak: 1)
        // …then a turn whose pressure still justifies eased (target == current) breaks the streak.
        let blipped = CoolHeadPolicy.next(building, target: .eased, minRecoveryTurns: 3)
        #expect(blipped == CoolHeadState(level: .eased, recoverStreak: 0))
    }

    @Test("recovery steps to the target level once the dwell clears")
    func recoversToTarget() {
        let armed = CoolHeadState(level: .minimal, recoverStreak: 1)
        let recovered = CoolHeadPolicy.next(armed, target: .full, minRecoveryTurns: 2)
        #expect(recovered.level == .full)
    }

    // MARK: - effort knobs per level

    @Test("full is unconstrained; eased trims iterations + pauses background; minimal defers heavy gen")
    func effortKnobs() {
        #expect(CoolHeadPolicy.maxIterations(for: .full, base: 5) == 5)
        #expect(CoolHeadPolicy.maxIterations(for: .eased, base: 5) == 3)
        #expect(CoolHeadPolicy.maxIterations(for: .minimal, base: 5) == 1)
        // Never raise a caller's already-low budget.
        #expect(CoolHeadPolicy.maxIterations(for: .eased, base: 1) == 1)

        #expect(CoolHeadPolicy.allowsBackgroundWork(.full))
        #expect(!CoolHeadPolicy.allowsBackgroundWork(.eased))
        #expect(!CoolHeadPolicy.allowsBackgroundWork(.minimal))

        #expect(!CoolHeadPolicy.defersHeavyGeneration(.full))
        #expect(!CoolHeadPolicy.defersHeavyGeneration(.eased))
        #expect(CoolHeadPolicy.defersHeavyGeneration(.minimal))
    }

    @Test("levels order by severity (full < eased < minimal)")
    func severityOrdering() {
        #expect(CoolHeadLevel.full < .eased)
        #expect(CoolHeadLevel.eased < .minimal)
    }
}
