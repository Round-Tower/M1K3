//
//  PlaybackWaitTests.swift
//  M1K3VoiceTests
//
//  Pins PlaybackWait: who ended a plain-path playback wait, and what the stall
//  streak hears about it (#471 review 2, finding 1).
//
//  Signed: Kev + claude-opus-5.5, 2026-10-05, Confidence 0.85, Prior: Unknown

@testable import M1K3Voice
import Testing

struct PlaybackWaitTests {
    @Test("a clean played-back end is a completion — the streak hears the engine is healthy")
    func playedBackCompletes() {
        var wait = PlaybackWait()
        let generation = wait.begin()
        #expect(wait.end(.playedBack, generation: generation) == .completed)
    }

    @Test("the deadline firing first is a stall; the late played-back callback is then ignored")
    func deadlineThenLateCallback() {
        var wait = PlaybackWait()
        let generation = wait.begin()
        #expect(wait.end(.deadline, generation: generation) == .stalled)
        #expect(wait.end(.playedBack, generation: generation) == nil)
    }

    @Test("a cancel is neither a completion nor a stall, and the stop's own callback counts for nothing")
    func cancelIsNeutral() {
        var wait = PlaybackWait()
        let generation = wait.begin()
        #expect(wait.end(.cancelled, generation: wait.generation) == .cancelled)
        #expect(wait.end(.playedBack, generation: generation) == nil)
        #expect(wait.end(.deadline, generation: generation) == nil)
    }

    @Test("an earlier playback's late callback never resolves the next utterance's wait")
    func staleGenerationIsIgnored() {
        var wait = PlaybackWait()
        let first = wait.begin()
        _ = wait.end(.cancelled, generation: wait.generation)
        let second = wait.begin()
        #expect(wait.end(.playedBack, generation: first) == nil)
        #expect(wait.end(.playedBack, generation: second) == .completed)
    }

    @Test("ending with no wait open is a no-op")
    func nothingOpen() {
        var wait = PlaybackWait()
        #expect(wait.end(.cancelled, generation: wait.generation) == nil)
    }

    @Test("two stalls then a clean text playback clear the streak, so one later stall retries the engine")
    func completionAfterRecoveryClearsTheStreak() {
        // The finding itself: the probe that won on the plain path never called
        // recordSuccess, so the streak stayed at 2 and the next single stall
        // routed straight back to the plain voice.
        var streak = PlaybackStallStreak()
        streak.recordStall()
        streak.recordStall()
        var wait = PlaybackWait()
        if wait.end(.playedBack, generation: wait.begin()) == .completed { streak.recordSuccess() }
        streak.recordStall()
        #expect(streak.route == .engine)
    }
}
