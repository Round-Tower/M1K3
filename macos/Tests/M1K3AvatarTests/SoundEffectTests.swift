//
//  SoundEffectTests.swift
//  M1K3AvatarTests
//
//  The earcon catalogue + bundling contract: every effect the app can fire
//  must resolve to a bundled WAV (same "bundled == playable" discipline as the
//  companion clips). The AVAudioPlayer playback itself is verify-by-launch.
//

@testable import M1K3Avatar
import Testing

struct SoundEffectTests {
    @Test("the catalogue is the synthesised vocabulary plus the dial-up loop")
    func catalogue() {
        #expect(Set(SoundEffect.allCases) == [
            .error, .save, .voiceEnter, .voiceExit, .listenStart, .endpointHeard, .thinkingTick,
            .toolCall, .answerLanded, .stop, .soundMark, .dialup,
        ])
        #expect(SoundEffect.allCases.filter { $0.source != .synth } == [.dialup])
    }

    @Test("the dial-up is the one bundled WAV, and it resolves")
    func dialupBundled() {
        #expect(SoundEffect.dialup.source == .bundled("dialup"))
        #expect(SoundEffectAssets.url(for: .dialup) != nil)
        #expect(SoundEffectAssets.url(for: .save) == nil)
    }

    @Test("every effect is playable — bundled resolves, synth renders")
    func everyEffectPlayable() {
        #expect(SoundEffectAssets.allInstalled)
    }
}
