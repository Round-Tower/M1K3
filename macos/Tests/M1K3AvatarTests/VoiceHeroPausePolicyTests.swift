@testable import M1K3Avatar
import Testing

/// The voice hero is what the user is talking to (Kev, 2026-10-09): it must NOT
/// freeze while M1K3 thinks or speaks — unlike the chat backdrop, which recedes
/// under streaming text. Only the system asks stop it: Low Power, Reduce Motion.
struct VoiceHeroPausePolicyTests {
    @Test("a live hero animates — nothing about the turn pauses it")
    func liveHeroAnimates() {
        #expect(!VoiceHeroPausePolicy.paused(lowPower: false, reduceMotion: false))
    }

    @Test("Low Power pauses the hero (the GPU is shared with MLX, ASR and TTS)")
    func lowPowerPauses() {
        #expect(VoiceHeroPausePolicy.paused(lowPower: true, reduceMotion: false))
    }

    @Test("Reduce Motion pauses the hero")
    func reduceMotionPauses() {
        #expect(VoiceHeroPausePolicy.paused(lowPower: false, reduceMotion: true))
        #expect(VoiceHeroPausePolicy.paused(lowPower: true, reduceMotion: true))
    }
}
