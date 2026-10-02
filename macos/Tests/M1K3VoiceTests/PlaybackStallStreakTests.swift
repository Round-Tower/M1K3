//
//  PlaybackStallStreakTests.swift
//  M1K3VoiceTests
//
//  The consecutive-stall fallback policy, pure: when the engine path is abandoned
//  for plain AVSpeech, and how it earns its way back.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-02, Confidence 0.85, Prior: Unknown

@testable import M1K3Voice
import Testing

struct PlaybackStallStreakTests {
    private func stalled(_ times: Int) -> PlaybackStallStreak {
        var streak = PlaybackStallStreak()
        for _ in 0 ..< times {
            streak.recordStall()
        }
        return streak
    }

    @Test("a fresh streak uses the engine")
    func fresh() {
        #expect(PlaybackStallStreak().route == .engine)
    }

    @Test("one stall still retries the engine (the rebuild is the retry)")
    func oneStallRetries() {
        #expect(stalled(1).route == .engine)
    }

    @Test("two consecutive stalls route to the plain voice")
    func twoStallsFallBack() {
        #expect(stalled(PlaybackStallStreak.fallbackThreshold).route == .plain)
    }

    @Test("a successful playback clears the streak")
    func successResets() {
        var streak = stalled(1)
        streak.recordSuccess()
        streak.recordStall()
        #expect(streak.route == .engine) // 1 stall, not 2: the success broke the run
    }

    @Test("a reset (route change) clears a fallback")
    func resetClears() {
        var streak = stalled(3)
        streak.reset()
        #expect(streak == PlaybackStallStreak())
    }

    @Test("peeking at the route never advances the probe cycle")
    func peekIsPure() {
        let streak = stalled(2)
        #expect(streak.route == streak.route)
        #expect(streak.plainUtterancesSinceStall == 0)
    }

    @Test("in fallback, every probeInterval-th utterance probes the engine")
    func probesPeriodically() {
        var streak = stalled(2)
        var routes: [PlaybackStallStreak.Route] = []
        for _ in 0 ..< PlaybackStallStreak.probeInterval {
            routes.append(streak.consumeRoute())
        }
        let plain = Array(repeating: PlaybackStallStreak.Route.plain, count: PlaybackStallStreak.probeInterval - 1)
        #expect(routes == plain + [.engine])
    }

    @Test("a probe that stalls returns to plain for a full cycle")
    func failedProbeFallsBackAgain() {
        var streak = stalled(2)
        for _ in 0 ..< PlaybackStallStreak.probeInterval - 1 {
            _ = streak.consumeRoute()
        }
        #expect(streak.consumeRoute() == .engine) // the probe
        streak.recordStall()
        #expect(streak.route == .plain)
    }

    @Test("a probe that plays clears the fallback entirely")
    func successfulProbeRecovers() {
        var streak = stalled(2)
        for _ in 0 ..< PlaybackStallStreak.probeInterval - 1 {
            _ = streak.consumeRoute()
        }
        streak.recordSuccess()
        #expect(streak.route == .engine)
        #expect(streak.consecutiveStalls == 0)
    }
}
