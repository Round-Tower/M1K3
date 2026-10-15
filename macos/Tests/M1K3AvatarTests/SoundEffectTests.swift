//
//  SoundEffectTests.swift
//  M1K3AvatarTests
//
//  The earcon catalogue + bundling contract: every effect the app can fire
//  must resolve to a bundled sound (same "bundled == playable" discipline as the
//  companion clips). The AVAudioPlayer playback itself is verify-by-launch.
//
//  Signed: claude-opus-5-5, 2026-10-15 (the dial-up's lossless size budget). Prior: Unknown.
//

import AVFoundation
@testable import M1K3Avatar
import Testing

struct SoundEffectTests {
    @Test("the catalogue is the synthesised vocabulary plus the dial-up loop")
    func catalogue() {
        #expect(Set(SoundEffect.allCases) == [
            .error, .save, .voiceEnter, .voiceExit, .listenStart, .endpointHeard, .thinkingTick,
            .toolCall, .answerLanded, .stop, .soundMark, .dialup,
            .doorPick, .cardTurn, .selectionTick, .wakeChime, .doneChord,
        ])
        #expect(SoundEffect.allCases.filter { $0.source != .synth } == [.dialup])
    }

    @Test("the dial-up is the one bundled sound, and it resolves")
    func dialupBundled() {
        #expect(SoundEffect.dialup.source == .bundled("dialup"))
        #expect(SoundEffectAssets.url(for: .dialup) != nil)
        #expect(SoundEffectAssets.url(for: .save) == nil)
    }

    @Test("the dial-up decodes, keeps its full loop, and stays inside its size budget")
    func dialupIsLosslessAndSmall() throws {
        let url = try #require(SoundEffectAssets.url(for: .dialup))
        let file = try AVAudioFile(forReading: url)
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        #expect(abs(seconds - 28.728) < 0.05) // the whole modem handshake, not a trimmed loop
        #expect(file.processingFormat.channelCount == 2)
        // Lossless ALAC is about a third of the PCM WAV (2.8 MB): a loop can't carry AAC's priming gap.
        let bytes = try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        #expect(bytes < 1_200_000)
        // What production plays it with (SoundEffectPlayer's pool) accepts the format.
        let player = try AVAudioPlayer(contentsOf: url)
        player.numberOfLoops = -1
        #expect(player.prepareToPlay())
        #expect(abs(player.duration - 28.728) < 0.05)
    }

    @Test("every effect is playable — bundled resolves, synth renders")
    func everyEffectPlayable() {
        #expect(SoundEffectAssets.allInstalled)
    }
}
