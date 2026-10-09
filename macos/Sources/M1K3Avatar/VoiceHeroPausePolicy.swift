//
//  VoiceHeroPausePolicy.swift
//  M1K3Avatar
//
//  When the full-bleed voice hero (the phone's VoiceScreen face) stops its clock.
//  The hero is what the user is talking to, so the turn never pauses it — it keeps
//  thinking and speaking in front of them, as the Mac hero does. That is the
//  deliberate difference from ChatBackdropTreatment, which recedes and stills
//  the chat BACKDROP under streaming text. Only the system's asks stop it:
//  Low Power (the GPU is shared with MLX, ASR and TTS) and Reduce Motion.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-09, Confidence 0.85 (Kev's ruling:
//  "it must not freeze while M1K3 thinks or speaks"; the cost of a live hero
//  beside decode on a phone is the accepted trade). Prior: none (new file).
//

public enum VoiceHeroPausePolicy {
    /// Pause the hero's motion only for Low Power or Reduce Motion.
    public static func paused(lowPower: Bool, reduceMotion: Bool) -> Bool {
        lowPower || reduceMotion
    }
}
