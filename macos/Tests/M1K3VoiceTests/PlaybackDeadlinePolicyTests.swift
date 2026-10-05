//
//  PlaybackDeadlinePolicyTests.swift
//  M1K3VoiceTests
//
//  The pure math behind the bounded playback wait (2026-10-02 voice hang: a
//  running-but-failing engine never delivered .dataPlayedBack, so the wait
//  suspended forever).
//
//  Signed: Kev + claude-opus-5-5, 2026-10-02, Confidence 0.85, Prior: Unknown

@testable import M1K3Voice
import Testing

struct PlaybackDeadlinePolicyTests {
    @Test("deadline is the scheduled audio duration plus the grace")
    func durationPlusGrace() {
        let policy = PlaybackDeadlinePolicy(grace: .seconds(3))
        #expect(policy.deadline(scheduledSamples: 48000, sampleRate: 24000) == .seconds(5))
    }

    @Test("the default grace is three seconds")
    func defaultGrace() {
        #expect(PlaybackDeadlinePolicy().grace == .seconds(3))
    }

    @Test("nothing scheduled still gets the grace, never zero")
    func emptyGetsGrace() {
        #expect(PlaybackDeadlinePolicy().deadline(scheduledSamples: 0, sampleRate: 24000) == .seconds(3))
    }

    @Test("a nonsense sample rate degrades to the grace alone")
    func badRate() {
        #expect(PlaybackDeadlinePolicy().deadline(scheduledSamples: 1000, sampleRate: 0) == .seconds(3))
        #expect(PlaybackDeadlinePolicy().deadline(scheduledSamples: 1000, sampleRate: -5) == .seconds(3))
    }

    @Test("a negative sample count is clamped")
    func negativeSamples() {
        #expect(PlaybackDeadlinePolicy().deadline(scheduledSamples: -10, sampleRate: 24000) == .seconds(3))
    }

    @Test("fractional seconds survive")
    func fractional() {
        let deadline = PlaybackDeadlinePolicy(grace: .seconds(2)).deadline(scheduledSamples: 12000, sampleRate: 24000)
        #expect(deadline == .milliseconds(2500))
    }
}
