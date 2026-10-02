//
//  EngineStallPolicyTests.swift
//  M1K3VoiceTests
//
//  How EffectfulSpeechProvider feeds PlaybackStallStreak and the stall counter:
//  deadline stalls build the streak toward the plain fallback, a completed
//  playback clears it, and a route-change cut-off is "not spoken" without being
//  evidence that the engine is broken. Headless: no audio is played.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-02, Confidence 0.8, Prior: Unknown

import Foundation
@testable import M1K3Voice
import Testing

@MainActor
struct EngineStallPolicyTests {
    private func stall(_ provider: EffectfulSpeechProvider) {
        provider.noteEnginePlaybackStalled(scheduledSamples: 24000, sampleRate: 24000)
    }

    @Test("two consecutive deadline stalls send the next utterance to the plain voice")
    func consecutiveStallsFallBack() {
        let provider = EffectfulSpeechProvider()
        #expect(provider.stallRoute == .engine)
        stall(provider)
        #expect(provider.stallRoute == .engine)
        stall(provider)
        #expect(provider.stallRoute == .plain)
    }

    @Test("a completed playback clears the streak")
    func completionClears() {
        let provider = EffectfulSpeechProvider()
        stall(provider)
        provider.notePlaybackCompleted()
        stall(provider)
        #expect(provider.stallRoute == .engine)
    }

    @Test("a configuration change while idle changes nothing the MCP layer sees")
    func idleConfigChange() {
        let provider = EffectfulSpeechProvider()
        provider.handleEngineConfigurationChange()
        #expect(provider.playbackStallCount == 0)
    }

    @Test("a configuration change that cuts off a line counts as not spoken")
    func interruptedConfigChangeCounts() {
        let provider = EffectfulSpeechProvider()
        provider.streamingSession = StreamingPlaybackSession(
            player: provider.player, sampleRate: 24000, onTimeline: { _ in }, onWord: { _ in }
        )
        provider.handleEngineConfigurationChange()
        #expect(provider.playbackStallCount == 1)
        #expect(provider.streamingSession == nil)
    }

    @Test("a route change is a fresh start for the streak, not a stall in it")
    func configChangeResetsStreak() {
        let provider = EffectfulSpeechProvider()
        stall(provider)
        provider.handleEngineConfigurationChange()
        stall(provider)
        #expect(provider.stallRoute == .engine)
    }

    @Test("the playback sleeper is injected at init, not mutated afterwards")
    func injectedSleeper() async throws {
        let box = SleeperProbe()
        let provider = EffectfulSpeechProvider(playbackSleeper: { await box.record($0) })
        try await provider.playbackSleeper(.seconds(7))
        #expect(await box.seen == [.seconds(7)])
    }
}

private actor SleeperProbe {
    private(set) var seen: [Duration] = []
    func record(_ duration: Duration) {
        seen.append(duration)
    }
}
