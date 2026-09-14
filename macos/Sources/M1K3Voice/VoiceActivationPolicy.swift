//
//  VoiceActivationPolicy.swift
//  M1K3Voice
//
//  What voice mode does with an audio-session activation result. Activation runs
//  off the main actor and the idle face stays tappable meanwhile, so two taps can
//  race two activations (#301). Only a loop still parked at idle acts on a result;
//  once the loop has left idle, the other tap won and any late result is ignored.
//  Otherwise a late `false` resets the avatar and says "Couldn't open the
//  microphone" while the controller is really listening.
//
//  Signed: Kev + claude-opus-5, 2026-09-14, Confidence 0.9. Prior: none (new file).
//

public enum VoiceActivationPolicy {
    public enum Outcome: Equatable, Sendable {
        /// The session is record-capable: arm the loop.
        case arm
        /// The session failed and the loop is parked: say so, tap to retry.
        case park
        /// The loop already moved on (armed by the other tap, or the mode ended).
        case ignore
    }

    public static func outcome(sessionActive: Bool, loop state: VoiceLoopState) -> Outcome {
        guard state == .idle else { return .ignore }
        return sessionActive ? .arm : .park
    }
}
