//
//  CoolHeadVoiceTests.swift
//  M1K3LanguageModelTests
//
//  Cool Head speaks (#697 Phase 1): when a send's pressure eases M1K3's effort, that one turn
//  carries one honest line, picked from a fixed set, never generated. The honesty is the point,
//  so it is pinned over every exemplar: the line says only what `ProcessInfo` reported (warm,
//  hot, Low Power Mode, the system asking to go easy), never a number it didn't read and never a
//  fan, a battery or a chip it can't see. Tied to the transition, so a hot spell gets one line.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-26, Confidence 0.85 (pure; the copy is Kev's to hear
//  before it ships). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-26 — #697 pre-push review fold: the forbidden stems match the scorer's
//  claim (chip, silicon, temperature, thermal, percent joined them). Confidence 0.9.
//

import Foundation
@testable import M1K3LanguageModel
import Testing

struct CoolHeadVoiceTests {
    // MARK: - cause: what the reading was, in the terms the line may use

    @Test("the cause follows the target table: heat dominates Low Power, a cool machine has none")
    func causeFollowsTheTargetTable() {
        #expect(CoolHeadPolicy.cause(thermal: .serious, lowPower: false) == .heat)
        #expect(CoolHeadPolicy.cause(thermal: .critical, lowPower: false) == .heat)
        #expect(CoolHeadPolicy.cause(thermal: .serious, lowPower: true) == .heat)
        #expect(CoolHeadPolicy.cause(thermal: .critical, lowPower: true) == .heat)
        #expect(CoolHeadPolicy.cause(thermal: .nominal, lowPower: true) == .lowPower)
        #expect(CoolHeadPolicy.cause(thermal: .fair, lowPower: true) == .lowPower)
        #expect(CoolHeadPolicy.cause(thermal: .nominal, lowPower: false) == nil)
        #expect(CoolHeadPolicy.cause(thermal: .fair, lowPower: false) == nil)
    }

    @Test("every reading that eases has a cause, and every reading that doesn't has none")
    func causeAgreesWithTarget() {
        let states: [ProcessInfo.ThermalState] = [.nominal, .fair, .serious, .critical]
        for thermal in states {
            for lowPower in [false, true] {
                let target = CoolHeadPolicy.target(thermal: thermal, lowPower: lowPower)
                let cause = CoolHeadPolicy.cause(thermal: thermal, lowPower: lowPower)
                #expect((target > .full) == (cause != nil), "\(thermal.rawValue) lowPower \(lowPower)")
            }
        }
    }

    // MARK: - announcement: the rise into eased, once per degrade episode

    @Test("only the rise into eased announces; holding, deepening, recovering and minimal say nothing")
    func announcesOnlyTheRiseIntoEased() {
        let full = CoolHeadState(level: .full)
        let eased = CoolHeadState(level: .eased)
        let minimal = CoolHeadState(level: .minimal)
        #expect(CoolHeadPolicy.announcement(from: full, to: eased, cause: .heat) == .heat)
        #expect(CoolHeadPolicy.announcement(from: full, to: eased, cause: .lowPower) == .lowPower)
        // Holding eased (a hot spell's later turns): nothing more to say.
        #expect(CoolHeadPolicy.announcement(from: eased, to: eased, cause: .heat) == nil)
        // Minimal's whole answer is already the honest deferral.
        #expect(CoolHeadPolicy.announcement(from: eased, to: minimal, cause: .heat) == nil)
        #expect(CoolHeadPolicy.announcement(from: full, to: minimal, cause: .heat) == nil)
        // A partial recovery and a full one say nothing in Phase 1.
        #expect(CoolHeadPolicy.announcement(from: minimal, to: eased, cause: .heat) == nil)
        #expect(CoolHeadPolicy.announcement(from: eased, to: full, cause: nil) == nil)
        // No cause, no line: the reading is what the line is about.
        #expect(CoolHeadPolicy.announcement(from: full, to: eased, cause: nil) == nil)
    }

    @Test("a hot spell announces once; after a sustained recovery the next spell announces again")
    func oneLinePerDegradeEpisode() {
        var state = CoolHeadState()
        var announced: [CoolHeadCause?] = []
        let readings: [(ProcessInfo.ThermalState, Bool)] = [
            (.nominal, false), (.serious, false), (.serious, false), (.fair, false), (.serious, false),
            (.nominal, false), (.nominal, false), (.nominal, false), (.nominal, true),
        ]
        for (thermal, lowPower) in readings {
            let step = CoolHeadPolicy.advance(state, thermal: thermal, lowPower: lowPower, minRecoveryTurns: 3)
            announced.append(step.announcement)
            state = step.state
        }
        // Cool, heat (announced), held, a blip that resets relief, held, three cool turns to recover,
        // then Low Power: a new episode with its own line.
        #expect(announced == [nil, .heat, nil, nil, nil, nil, nil, nil, .lowPower])
    }

    @Test("advance carries next's hysteresis unchanged")
    func advanceIsNext() {
        let current = CoolHeadState(level: .eased, recoverStreak: 1)
        for thermal in [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical] {
            let step = CoolHeadPolicy.advance(current, thermal: thermal, lowPower: false, minRecoveryTurns: 3)
            let target = CoolHeadPolicy.target(thermal: thermal, lowPower: false)
            #expect(step.state == CoolHeadPolicy.next(current, target: target, minRecoveryTurns: 3))
        }
    }

    // MARK: - the lines

    /// Words a line may never use: nothing here reads a fan (fanless Airs have none), a battery
    /// (Low Power Mode exists on desktops), a charger, a chip's load, a temperature or a percentage.
    /// Matched as substrings, so "fans" and "charging" are caught by their stems.
    private static let forbiddenStems = [
        "fan", "batter", "charg", "plugged", "cpu", "gpu", "chip", "silicon", "memory", "degree", "temperature",
        "thermal", "percent",
    ]

    @Test(
        "every line is honest: no number, no percent, no fan, battery, charger or chip",
        arguments: CoolHeadCause.allCases
    )
    func everyLineIsHonest(cause: CoolHeadCause) {
        for noun in ["machine", "device", "Vision Pro"] {
            for line in CoolHeadVoice.exemplars(for: cause, deviceNoun: noun) {
                let hasNumber = line.contains { $0.isNumber }
                #expect(!hasNumber, "a number: \(line)")
                #expect(!line.contains("%"), "a percent: \(line)")
                let lowered = line.lowercased()
                for stem in Self.forbiddenStems {
                    #expect(!lowered.contains(stem), "\(stem) in: \(line)")
                }
                #expect((20 ... 100).contains(line.count), "\(line.count) chars: \(line)")
                #expect(line.hasSuffix("."), "ends without a full stop: \(line)")
            }
        }
    }

    @Test("each cause speaks of its own reading")
    func linesNameTheirReading() {
        for line in CoolHeadVoice.exemplars(for: .heat, deviceNoun: "machine") {
            let lowered = line.lowercased()
            #expect(lowered.contains("warm") || lowered.contains("hot"), "heat line without heat: \(line)")
            #expect(!lowered.contains("low power"), "heat line claims Low Power: \(line)")
        }
        for line in CoolHeadVoice.exemplars(for: .lowPower, deviceNoun: "machine") {
            #expect(line.contains("Low Power Mode"), "Low Power line without it: \(line)")
            let lowered = line.lowercased()
            #expect(!lowered.contains("warm") && !lowered.contains("hot"), "Low Power line claims heat: \(line)")
        }
        for line in CoolHeadVoice.exemplars(for: .unknownPressure, deviceNoun: "machine") {
            let lowered = line.lowercased()
            #expect(!lowered.contains("warm") && !lowered.contains("hot") && !lowered.contains("low power"),
                    "an unknown pressure line names a cause it didn't read: \(line)")
        }
    }

    @Test("every cause has at least two lines, and no two lines anywhere are the same")
    func linesAreDistinct() {
        let all = CoolHeadCause.allCases.flatMap { CoolHeadVoice.exemplars(for: $0, deviceNoun: "machine") }
        for cause in CoolHeadCause.allCases {
            #expect(CoolHeadVoice.exemplars(for: cause, deviceNoun: "machine").count >= 2)
        }
        #expect(Set(all).count == all.count)
    }

    @Test("the pick is deterministic and cycles through every exemplar", arguments: CoolHeadCause.allCases)
    func pickIsDeterministicAndCycles(cause: CoolHeadCause) {
        let exemplars = CoolHeadVoice.exemplars(for: cause, deviceNoun: "machine")
        let picked = (0 ..< exemplars.count).map { CoolHeadVoice.line(for: cause, pick: $0, deviceNoun: "machine") }
        #expect(picked == exemplars)
        #expect(CoolHeadVoice.line(for: cause, pick: exemplars.count, deviceNoun: "machine") == exemplars[0])
        #expect(CoolHeadVoice.line(for: cause, pick: 1, deviceNoun: "machine")
            == CoolHeadVoice.line(for: cause, pick: 1, deviceNoun: "machine"))
        // A counter that ever went negative still lands on a line.
        #expect(exemplars.contains(CoolHeadVoice.line(for: cause, pick: -1, deviceNoun: "machine")))
    }

    @Test("the device noun is threaded, never a hardcoded Mac")
    func deviceNounIsThreaded() {
        for cause in [CoolHeadCause.heat, .unknownPressure] {
            let lines = CoolHeadVoice.exemplars(for: cause, deviceNoun: "Vision Pro")
            #expect(lines.contains { $0.contains("Vision Pro") }, "\(cause) never names the device")
            #expect(!CoolHeadVoice.exemplars(for: cause, deviceNoun: "machine").contains { $0.contains("Vision Pro") })
        }
        for cause in CoolHeadCause.allCases {
            for line in CoolHeadVoice.exemplars(for: cause, deviceNoun: "device") {
                #expect(!line.contains("Mac"), "a hardcoded Mac: \(line)")
            }
        }
    }

    // MARK: - the slot: one send's line, read once by that send's turn

    @Test("the slot posts a line on an announcement and hands it out exactly once")
    func slotHandsTheLineOutOnce() {
        var slot = CoolHeadNoteSlot()
        slot.post(.heat, deviceNoun: "machine")
        #expect(slot.take() == CoolHeadVoice.line(for: .heat, pick: 0, deviceNoun: "machine"))
        #expect(slot.take() == nil)
    }

    @Test("a send with no announcement clears what an unread send left, so nothing stale carries")
    func slotOverwritesEverySend() {
        var slot = CoolHeadNoteSlot()
        slot.post(.heat, deviceNoun: "machine")
        slot.post(nil, deviceNoun: "machine")
        #expect(slot.take() == nil)
    }

    @Test("each announcement takes the next line in its set")
    func slotRotatesThePick() {
        var slot = CoolHeadNoteSlot()
        var lines: [String?] = []
        for _ in 0 ..< 3 {
            slot.post(.heat, deviceNoun: "machine")
            lines.append(slot.take())
        }
        let exemplars = CoolHeadVoice.exemplars(for: .heat, deviceNoun: "machine")
        #expect(lines == (0 ..< 3).map { exemplars[$0 % exemplars.count] })
        // A send that announces nothing doesn't move the rotation.
        slot.post(nil, deviceNoun: "machine")
        slot.post(.heat, deviceNoun: "machine")
        #expect(slot.take() == exemplars[3 % exemplars.count])
    }
}
