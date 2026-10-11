//
//  OnboardingVoiceLineTests.swift
//  M1K3InferenceTests
//
//  The one line M1K3 says when the setup deck finishes (Kev, TestFlight 499: "sound effects too" —
//  earcons plus a voice line). Pure copy + a pure speak/skip rule; the speaking itself is
//  verify-by-launch.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.85 (copy is Kev-approved verbatim in the
//  plan). Prior: none (new file).
//

@testable import M1K3Inference
import Testing

struct OnboardingVoiceLineTests {
    @Test("first run and re-run each get their own line, verbatim")
    func linesAreVerbatim() {
        #expect(OnboardingVoiceLine.line(isRerun: false) == "Right — let's get to work.")
        #expect(OnboardingVoiceLine.line(isRerun: true) == "Room's set. Back to it.")
    }

    @Test("the line is skipped while a voice is still loading, and spoken otherwise")
    func skipsWhileVoiceLoads() {
        func speaks(_ load: ModelLoadState, sound: Bool = true) -> Bool {
            OnboardingVoiceLine.shouldSpeak(voiceLoad: load, soundEffectsEnabled: sound, fullDoor: true)
        }
        #expect(!speaks(.progress(0.4)))
        #expect(!speaks(.preparing))
        #expect(speaks(.idle))
        #expect(speaks(.ready))
        // A failed neural voice fell back to the built-in one, which can speak.
        #expect(speaks(.failed(message: "offline")))
    }

    @Test("the Sound effects toggle silences the line too")
    func toggleSilencesTheLine() {
        #expect(!OnboardingVoiceLine.shouldSpeak(voiceLoad: .ready, soundEffectsEnabled: false, fullDoor: true))
    }

    @Test("the Private door stays silent: All features off means no spoken sign-off")
    func privateDoorIsSilent() {
        #expect(!OnboardingVoiceLine.shouldSpeak(voiceLoad: .ready, soundEffectsEnabled: true, fullDoor: false))
        #expect(OnboardingVoiceLine.shouldSpeak(voiceLoad: .ready, soundEffectsEnabled: true, fullDoor: true))
    }
}
