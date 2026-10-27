//
//  ChatEvalFixtures+MechanicTests.swift
//  M1K3EvalTests
//
//  The `mechanic` kind (#697 Phase 1) measures Cool Head's line on the turn's activity channel:
//  one honest note when the scenario's send eases effort, none when it doesn't, and an answer
//  beside it either way. The fixtures' shape is what makes that a fair read: every send is set
//  by a scenario (never the eval Mac's own heat), no prompt carries a number the note could be
//  confused with, critical heat stays out (its turn is the deferral), and a cool control says
//  nothing.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-26, Confidence 0.9 (pure). Prior: none (new file).
//

import Foundation
@testable import M1K3Eval
import Testing

struct ChatEvalFixturesMechanicTests {
    @Test("the kind is the mechanic set, five or more, ids prefixed mech-")
    func kindIsTheSet() {
        #expect(ChatEvalFixtures.mechanic.count >= 5)
        #expect(ChatEvalFixtures.fixtures(for: .mechanic) == ChatEvalFixtures.mechanic)
        for fixture in ChatEvalFixtures.mechanic {
            #expect(fixture.id.hasPrefix("mech-"), "\(fixture.id)")
            #expect(fixture.kind == .mechanic)
        }
        #expect(TaskKind.mechanic.rawValue == "mechanic")
    }

    @Test("every send is set by a scenario: the eval never reads its own Mac's heat")
    func everyFixtureCarriesAScenario() {
        for fixture in ChatEvalFixtures.mechanic {
            #expect(fixture.machine != nil, "\(fixture.id) has no scenario")
        }
        // Only the mechanic kind sets one: every other turn runs as it always did.
        for fixture in ChatEvalFixtures.all where fixture.kind != .mechanic {
            #expect(fixture.machine == nil, "\(fixture.id) carries a machine scenario")
        }
    }

    @Test("the scenarios cover heat and Low Power on a desktop and a laptop, plus a cool control; never critical")
    func scenariosCoverTheCauses() {
        let machines = ChatEvalFixtures.mechanic.compactMap(\.machine)
        #expect(machines.allSatisfy { $0.thermal != .critical }, "critical heat is the deferral's turn")
        #expect(machines.contains { $0.thermal == .serious && !$0.hasBattery })
        #expect(machines.contains { $0.thermal == .serious && $0.hasBattery })
        #expect(machines.contains { $0.thermal != .serious && $0.lowPower && !$0.hasBattery })
        #expect(machines.contains { $0.thermal != .serious && $0.lowPower && $0.hasBattery })
        #expect(machines.contains { !$0.expectsNote }, "no cool control")
        for machine in machines where machine.expectsNote {
            #expect(machine.thermal == .serious || machine.lowPower)
        }
    }

    @Test("no prompt carries a number, and none bounds the answer's length")
    func promptsAreDigitFree() {
        for fixture in ChatEvalFixtures.mechanic {
            let hasDigit = fixture.prompt.contains { $0.isNumber }
            #expect(!hasDigit, "\(fixture.id) prompt has a number")
            #expect(!fixture.expectation.lengthIsHard, "\(fixture.id) bounds the length")
            #expect(fixture.expectation.mustComply, "\(fixture.id): the turn must still answer")
        }
    }

    @Test("a scenario expects a note only for serious heat, or Low Power on a cool machine")
    func expectsNoteTable() {
        func scenario(_ thermal: ProcessInfo.ThermalState, _ lowPower: Bool) -> MachineScenario {
            MachineScenario(thermal: thermal, lowPower: lowPower, hasBattery: false)
        }
        #expect(scenario(.serious, false).expectsNote)
        #expect(scenario(.serious, true).expectsNote)
        #expect(scenario(.nominal, true).expectsNote)
        #expect(scenario(.fair, true).expectsNote)
        #expect(!scenario(.nominal, false).expectsNote)
        #expect(!scenario(.fair, false).expectsNote)
        // Critical goes straight to minimal from a fresh state: that turn's answer is the deferral.
        #expect(!scenario(.critical, false).expectsNote)
    }

    @Test("the kind sits last in all, so no earlier run's order moves")
    func mechanicIsLast() throws {
        let last = try #require(ChatEvalFixtures.all.last)
        #expect(last.kind == .mechanic)
        #expect(TaskKind.allCases.last == .mechanic)
    }
}
