//
//  PlaybackStallCountTests.swift
//  M1K3VoiceTests
//
//  The stall counter that lets a waited MCP speak report "not spoken" instead of
//  "Spoken." over silence (2026-10-02), and the provider's recovery seam.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-02, Confidence 0.8, Prior: Unknown
//  Review: Kev + claude-opus-5-5, 2026-10-02 (PR #471 round 2) — the swappable count is now
//  monotonic across tier swaps, `stalled(since:)` lives in M1K3Voice (moved out of the app),
//  and a config-change cut-off counts as not-spoken. Confidence now 0.85.

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

    @Test("a tier swap never makes the count go backwards")
    func monotonicAcrossSwaps() {
        let first = StallingProvider()
        first.playbackStallCount = 3
        let swappable = SwappableSpeechProvider(first)
        #expect(swappable.playbackStallCount == 3)

        let second = StallingProvider() // a fresh tier starts at its own zero
        swappable.setProvider(second)
        #expect(swappable.playbackStallCount == 3)
        second.playbackStallCount = 1
        #expect(swappable.playbackStallCount == 4)

        swappable.setProvider(PlainProvider()) // a tier that cannot stall
        #expect(swappable.playbackStallCount == 4)
    }

    @Test("a stall during a swappable's active tier is seen by stalled(since:)")
    func stalledSince() {
        let stalling = StallingProvider()
        let swappable = SwappableSpeechProvider(stalling)
        let before = swappable.playbackStallCount
        #expect(swappable.stalled(since: before) == false)
        swappable.setProvider(StallingProvider()) // swap mid-utterance
        stalling.playbackStallCount = 9 // the OUTGOING tier's count is no longer read
        #expect(swappable.stalled(since: before) == false)
        (swappable.active as? StallingProvider)?.playbackStallCount = 1
        #expect(swappable.stalled(since: before))
    }

    @Test("stalled(since:) is true only for a strict increase")
    func stalledIsStrict() {
        let stalling = StallingProvider()
        stalling.playbackStallCount = 2
        #expect(stalling.stalled(since: 2) == false)
        #expect(stalling.stalled(since: 3) == false)
        #expect(stalling.stalled(since: 1))
    }
}
