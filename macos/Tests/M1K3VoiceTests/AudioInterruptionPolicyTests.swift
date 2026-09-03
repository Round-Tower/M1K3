//
//  AudioInterruptionPolicyTests.swift
//  M1K3VoiceTests
//
//  What voice mode does when the OS takes the audio session away — a phone
//  call, Siri, headphones pulled, the media server restarting. Pure mapping,
//  pinned here so the answer to "why did M1K3 stop talking" is a table, not a
//  guess. The rule of thumb: never keep speaking or listening through an
//  interruption, never resume the mic unasked, never blast the speaker after
//  headphones come out.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-03, Confidence 0.85. Prior: none
//  (new file; the loop it drives is VoiceLoopMachine, Kev + claude-fable-5).
//

import M1K3Voice
import Testing

struct AudioInterruptionPolicyTests {
    private static let active: [VoiceLoopState] = [
        .listening(partial: "hello"),
        .awaitingAnswer(question: "hello"),
        .speaking(answer: "Hi there."),
    ]

    @Test("an interruption beginning pauses every active state")
    func interruptionBeganPausesActive() {
        for state in Self.active {
            #expect(AudioInterruptionPolicy.action(for: .interruptionBegan, in: state) == .pause)
        }
    }

    @Test("an interruption beginning is nothing to a parked or ended loop")
    func interruptionBeganIgnoredWhenParked() {
        #expect(AudioInterruptionPolicy.action(for: .interruptionBegan, in: .idle) == .none)
        #expect(AudioInterruptionPolicy.action(for: .interruptionBegan, in: .ended) == .none)
    }

    @Test("an interruption ending never resumes the mic unasked — even when the OS says it may")
    func interruptionEndedNeverResumes() {
        for state in Self.active + [.idle, .ended] {
            #expect(AudioInterruptionPolicy.action(for: .interruptionEnded(shouldResume: true), in: state) == .none)
            #expect(AudioInterruptionPolicy.action(for: .interruptionEnded(shouldResume: false), in: state) == .none)
        }
    }

    @Test("headphones pulled pauses every active state — the answer must not jump to the speaker")
    func oldDeviceUnavailablePausesActive() {
        for state in Self.active {
            let action = AudioInterruptionPolicy.action(for: .routeChanged(reason: .oldDeviceUnavailable), in: state)
            #expect(action == .pause)
        }
        #expect(AudioInterruptionPolicy.action(for: .routeChanged(reason: .oldDeviceUnavailable), in: .idle) == .none)
    }

    @Test("other route changes (headphones plugged in, category change) are left alone")
    func otherRouteChangesIgnored() {
        for state in Self.active {
            #expect(AudioInterruptionPolicy.action(for: .routeChanged(reason: .newDeviceAvailable), in: state) == .none)
            #expect(AudioInterruptionPolicy.action(for: .routeChanged(reason: .other), in: state) == .none)
        }
    }

    @Test("a media-services reset ends the mode from any state — the session underneath is gone")
    func mediaServicesResetExits() {
        for state in Self.active + [.idle] {
            #expect(AudioInterruptionPolicy.action(for: .mediaServicesReset, in: state) == .exit)
        }
        #expect(AudioInterruptionPolicy.action(for: .mediaServicesReset, in: .ended) == .none)
    }
}
