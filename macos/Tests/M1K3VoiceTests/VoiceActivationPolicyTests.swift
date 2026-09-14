//
//  VoiceActivationPolicyTests.swift
//  M1K3VoiceTests
//
//  What voice mode does with an audio-session activation result (#301). The
//  idle face stays tappable through the activation `await`, so two taps can race
//  two activations. A result that lands after the loop has already left idle
//  belongs to a race the loop has moved past: it must neither re-arm nor paint
//  "Couldn't open the microphone" over a loop that is really listening.
//
//  Signed: Kev + claude-opus-5, 2026-09-14, Confidence 0.9. Prior: none (new file).
//

import M1K3Voice
import Testing

struct VoiceActivationPolicyTests {
    private static let running: [VoiceLoopState] = [
        .listening(partial: ""),
        .awaitingAnswer(question: "hello"),
        .speaking(answer: "Hi there."),
    ]

    @Test("a session that came up arms a parked loop")
    func activeArmsIdle() {
        #expect(VoiceActivationPolicy.outcome(sessionActive: true, loop: .idle) == .arm)
    }

    @Test("a session that failed parks an idle loop with the reason")
    func failureParksIdle() {
        #expect(VoiceActivationPolicy.outcome(sessionActive: false, loop: .idle) == .park)
    }

    @Test("a late failure never misreports a loop the other tap already armed")
    func lateFailureIgnoredWhileRunning() {
        for state in Self.running {
            #expect(VoiceActivationPolicy.outcome(sessionActive: false, loop: state) == .ignore)
        }
    }

    @Test("a late success leaves a running loop alone")
    func lateSuccessIgnoredWhileRunning() {
        for state in Self.running {
            #expect(VoiceActivationPolicy.outcome(sessionActive: true, loop: state) == .ignore)
        }
    }

    @Test("an ended loop takes nothing from a late activation")
    func endedIgnores() {
        #expect(VoiceActivationPolicy.outcome(sessionActive: true, loop: .ended) == .ignore)
        #expect(VoiceActivationPolicy.outcome(sessionActive: false, loop: .ended) == .ignore)
    }
}
