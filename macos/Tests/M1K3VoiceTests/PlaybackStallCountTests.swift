//
//  PlaybackStallCountTests.swift
//  M1K3VoiceTests
//
//  The stall counter that lets a waited MCP speak report "not spoken" instead of
//  "Spoken." over silence (2026-10-02), and the provider's recovery seam.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-02, Confidence 0.8, Prior: Unknown

import Foundation
@testable import M1K3Voice
import Testing

private final class StallingProvider: SpeechProviderWithPlaybackHealth, @unchecked Sendable {
    let name = "stalling"
    let isAvailable = true
    var playbackStallCount = 0
    func speak(_: SpeechUtterance) async {}
    func stop() async {}
    func isSpeaking() async -> Bool {
        false
    }
}

private final class PlainProvider: SpeechProvider, @unchecked Sendable {
    let name = "plain"
    let isAvailable = true
    func speak(_: SpeechUtterance) async {}
    func stop() async {}
    func isSpeaking() async -> Bool {
        false
    }
}

struct PlaybackStallCountTests {
    @Test("the swappable façade forwards the active tier's stall count")
    func forwards() {
        let stalling = StallingProvider()
        let swappable = SwappableSpeechProvider(stalling)
        #expect(swappable.playbackStallCount == 0)
        stalling.playbackStallCount = 2
        #expect(swappable.playbackStallCount == 2)
    }

    @Test("a tier that cannot stall reports zero")
    func plainTierIsZero() {
        #expect(SwappableSpeechProvider(PlainProvider()).playbackStallCount == 0)
    }

    @MainActor
    @Test("a provider's stall notice bumps the count the MCP layer samples")
    func providerCountsStalls() {
        let provider = EffectfulSpeechProvider()
        #expect(provider.playbackStallCount == 0)
        provider.noteEnginePlaybackStalled(scheduledSamples: 24000, sampleRate: 24000)
        #expect(provider.playbackStallCount == 1)
    }
}
