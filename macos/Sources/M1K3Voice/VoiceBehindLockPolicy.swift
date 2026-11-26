//
//  VoiceBehindLockPolicy.swift
//  M1K3Voice
//
//  The iPhone's voice conversation going on behind the lock screen, the way a phone call does. Until now the app
//  left voice mode as it left the foreground. iOS refuses GPU work in the background, so Lil, Big and the M1K3
//  voice (Kokoro, MLX on Metal) can't run there: a turn behind the lock is SpeechAnalyzer → an off-GPU brain
//  (Mini, Brain at Home, Private Cloud) → the system voice.
//
//  Kev's calls (2026-11-26): on by default, with a switch in Settings; when the chosen brain is Lil or Big, the
//  paired Mac answers, else Mini. A minute of silence ends the conversation (the mic is on, and the orange dot
//  says so, the whole time).
//
//  Measured on an iPhone 17 Pro by the throwaway spike (spike/bg-voice, 2026-11-17, unpaired, so Mini): 8/8
//  re-listens behind the lock with 0 errors, Mini's first audio 0.8–1.1 s. The Home route was not run there.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-26, Confidence 0.8 (pure and tested; the shell wiring is the phone
//  check). Prior: the spike's AppCore+BGVoiceSpike.swift (Kev + claude-opus-5.5, 2026-11-16/17), reduced to rules.
//

import Foundation

public enum VoiceBehindLockPolicy {
    /// The Settings switch's default (Kev: on).
    public static let onByDefault = true

    /// Who answers once the phone is locked.
    public enum Brain: Equatable, Sendable {
        /// The chosen brain already runs off this phone's GPU (Mini, Home, Private Cloud).
        case asChosen
        /// Lil or Big was chosen: the paired Mac answers instead.
        case home
        /// Lil or Big was chosen and no Mac is paired: Apple's on-device model answers.
        case mini
    }

    /// The brain for a conversation going behind the lock, or nil to leave voice mode as the app goes (no
    /// conversation, the switch off, or nobody off the GPU to answer).
    public static func brain(
        switchOn: Bool, voiceModeActive: Bool, chosenRunsOnThisGPU: Bool, homePaired: Bool, miniAvailable: Bool
    ) -> Brain? {
        guard switchOn, voiceModeActive else { return nil }
        guard chosenRunsOnThisGPU else { return .asChosen }
        if homePaired { return .home }
        return miniAvailable ? .mini : nil
    }

    /// Silence behind the lock that ends the conversation.
    public static let silenceLimit: Duration = .seconds(60)

    /// A turn still running (a slow tool, a long answer) is not silence: the spike's run 2 ended a conversation
    /// mid-turn on a 60 s web-search timeout.
    public static func endsForSilence(silentFor: Duration, turnRunning: Bool) -> Bool {
        !turnRunning && silentFor >= silenceLimit
    }

    /// In front, an interruption (a call, Siri) parks the loop until a tap. Behind the lock nobody can tap, so an
    /// interruption that ends with iOS's "should resume" picks the listen back up, if the loop is parked.
    public static func resumesAfterInterruption(shouldResume: Bool, loop: VoiceLoopState) -> Bool {
        shouldResume && loop == .idle
    }
}
