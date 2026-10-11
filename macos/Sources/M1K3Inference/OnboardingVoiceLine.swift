//
//  OnboardingVoiceLine.swift
//  M1K3Inference
//
//  The one line M1K3 speaks in its own voice when the setup deck finishes, after the done chord
//  (Kev, TestFlight 499: "we need sound effects too"; his call: synth earcons plus a voice line).
//  Pure copy and a pure speak/skip rule, beside `WakeProgressCopy`, so the shell only plays it.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.85 (the copy is the plan's, approved by
//  Kev; the timing against the chord is verify-by-ear). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-11 (pre-push review fold) — `delayAfterChord` 0.4 -> 0.65 s (the
//  chord rings to ~0.56 s; a test now renders it) and `shouldSpeak` takes `fullDoor`: the Private door
//  ("All features off") gets no spoken sign-off. Confidence 0.8.
//

import Foundation

public enum OnboardingVoiceLine {
    /// First run: the deck ends and the work starts. Re-run: the same room, tidied.
    public static func line(isRerun: Bool) -> String {
        isRerun ? "Room's set. Back to it." : "Right — let's get to work."
    }

    /// Breath between the done chord and the voice. Earcons are muted while M1K3 speaks, so the
    /// chord starts first and the line follows once it has landed.
    public static let delayAfterChord = Duration.milliseconds(650)

    /// Speak only when the user wants onboarding sound (the General ▸ Sound effects toggle) and
    /// no voice is mid-download or mid-prepare (the line would come out in a provider about to be
    /// swapped). A failed load already fell back to the built-in voice, so that one speaks.
    /// `fullDoor` is true only when the door chosen this session was Full: the Private door
    /// ("All features off") gets the chord and nothing spoken.
    public static func shouldSpeak(voiceLoad: ModelLoadState, soundEffectsEnabled: Bool, fullDoor: Bool) -> Bool {
        fullDoor && soundEffectsEnabled && !voiceLoad.isActive
    }
}
