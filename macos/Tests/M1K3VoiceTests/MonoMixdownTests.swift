//
//  MonoMixdownTests.swift
//  M1K3VoiceTests
//
//  Pins the pure DSP core of the tap-side downmix that lets Apple Speech hear
//  a multi-channel device at all: SFSpeech accepts >2-channel buffers and then
//  silently never produces a partial (Kev's 9-channel aggregate, 2026-08-14 —
//  "it just continues to listen"). Channels are SUMMED (WhisperKit's own
//  default ChannelMode precedent — on an aggregate device the live mic is ONE
//  channel beside silent siblings, so averaging would divide real speech by
//  nine) and clamped to [-1, 1].
//
//  Deliberately array-only: a first cut drove the AVAudioPCMBuffer adapter
//  with real layout-backed buffers and segfaulted the PARALLEL test run. The
//  adapter is verify-by-launch glue, per the transcriber's own convention.
//
//  Signed: Kev + claude-fable-5, 2026-08-14, Confidence 0.9. Prior: Unknown.

import M1K3Voice
import Testing

struct MonoMixdownTests {
    @Test("speech on one channel beside silent siblings survives undiminished")
    func oneLiveChannelSurvives() {
        // The aggregate-device shape: the live mic on one channel, silence on
        // the other eight. The sum IS the mic signal.
        let channels = [[Float]]([[0.5, -0.25]] + Array(repeating: [0.0, 0.0], count: 8))
        let mixed = MonoMixdown.mix(channels)
        #expect(mixed == [0.5, -0.25])
    }

    @Test("channels sum per frame")
    func channelsSum() {
        #expect(MonoMixdown.mix([[0.1, 0.2], [0.3, -0.1]]) == [0.4, 0.1])
    }

    @Test("the sum clamps to [-1, 1] — correlated channels can't clip the recognizer")
    func sumClamps() {
        #expect(MonoMixdown.mix([[0.8], [0.8], [0.8]]) == [1.0])
        #expect(MonoMixdown.mix([[-0.8], [-0.8], [-0.8]]) == [-1.0])
    }

    @Test("empty input mixes to empty, not a crash")
    func emptyInput() {
        #expect(MonoMixdown.mix([]) == [])
        #expect(MonoMixdown.mix([[], []]) == [])
    }

    @Test("a short channel reads as absent past its end")
    func shortChannelTolerated() {
        #expect(MonoMixdown.mix([[0.1, 0.2], [0.3]]) == [0.4, 0.2])
    }
}
