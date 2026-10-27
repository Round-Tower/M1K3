//
//  MechanicScenarioPolicyTests.swift
//  M1K3ChatTests
//
//  M1K3Eval may not link M1K3LanguageModel, so the `mechanic` kind's `MachineScenario.expectsNote`
//  is the fixture author's own table, written down apart from the policy (an oracle, not a mirror).
//  This target links both, so the table is held to the fold the app runs on every send: a scenario
//  expects a note exactly when `CoolHeadPolicy.advance` announces one from a fresh state, which is
//  the state the eval starts each fixture in.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-26, Confidence 0.9 (pure). Prior: none (new file).
//

import Foundation
import M1K3Eval
import M1K3LanguageModel
import Testing

struct MechanicScenarioPolicyTests {
    @Test("a scenario expects a note exactly when the app's Cool Head fold announces one")
    func expectsNoteIsThePolicy() {
        for thermal in [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical] {
            for lowPower in [false, true] {
                for hasBattery in [false, true] {
                    let scenario = MachineScenario(thermal: thermal, lowPower: lowPower, hasBattery: hasBattery)
                    let step = CoolHeadPolicy.advance(
                        CoolHeadState(), thermal: thermal, lowPower: lowPower, minRecoveryTurns: 3
                    )
                    #expect(
                        scenario.expectsNote == (step.announcement != nil),
                        "thermal \(thermal.rawValue), lowPower \(lowPower)"
                    )
                }
            }
        }
    }

    @Test("every mechanic fixture's note, run through the app's fold and slot, passes the scorer's honesty checks")
    func everyFixtureNoteIsHonest() {
        for fixture in ChatEvalFixtures.mechanic {
            guard let machine = fixture.machine else { continue }
            for noun in ["machine", "device", "Vision Pro"] {
                let step = CoolHeadPolicy.advance(
                    CoolHeadState(), thermal: machine.thermal, lowPower: machine.lowPower, minRecoveryTurns: 3
                )
                var slot = CoolHeadNoteSlot()
                slot.post(step.announcement, deviceNoun: noun)
                let notes = slot.take().map { [$0] } ?? []
                let score = ChatEvalScorer.score(
                    fixture: fixture,
                    observation: EvalObservation(rawText: "A plain, finished answer to the question.", turnNotes: notes)
                )
                for name in ["turn-note count", "note: no number", "note: no hardware claim"] {
                    let outcome = score.checks.first { $0.name == name }?.outcome
                    #expect(outcome != .fail, "\(fixture.id) [\(noun)]: \(name) — \(notes)")
                }
            }
        }
    }

    @Test("every line CoolHeadVoice can say passes the scorer's honesty checks, on every platform's noun")
    func everyExemplarPassesTheScorer() throws {
        let fixture = try #require(ChatEvalFixtures.mechanic.first { $0.machine?.expectsNote == true })
        for cause in CoolHeadCause.allCases {
            for noun in ["machine", "device", "Vision Pro"] {
                for line in CoolHeadVoice.exemplars(for: cause, deviceNoun: noun) {
                    let score = ChatEvalScorer.score(
                        fixture: fixture,
                        observation: EvalObservation(rawText: "A plain, finished answer.", turnNotes: [line])
                    )
                    for name in ["note: no number", "note: no hardware claim"] {
                        #expect(score.checks.first { $0.name == name }?.outcome == .pass, "\(name): \(line)")
                    }
                }
            }
        }
    }
}
