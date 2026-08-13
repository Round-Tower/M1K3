//
//  VoiceTurnTimelineTests.swift
//  M1K3VoiceTests
//

@testable import M1K3Voice
import Testing

struct VoiceTurnTimelineTests {
    /// A fixed origin so every expectation is an exact arithmetic claim — no
    /// sleeping, no tolerance windows.
    private let origin = ContinuousClock.now

    private func at(_ ms: Int) -> ContinuousClock.Instant {
        origin.advanced(by: .milliseconds(ms))
    }

    @Test("a turn that never started reports nothing")
    func silentBeforeTheTurn() {
        var timeline = VoiceTurnTimeline()
        timeline.endpointed(at: at(0))
        #expect(timeline.summary() == nil)
    }

    @Test("time to first audio is measured from the moment the speaker stopped")
    func firstAudioFromEndpoint() throws {
        var timeline = VoiceTurnTimeline()
        timeline.endpointed(at: at(0))
        timeline.turnStarted(at: at(40))
        timeline.chunkReady(at: at(2140))
        timeline.audioStarted(at: at(2750))
        timeline.completed(at: at(8900))

        let summary = try #require(timeline.summary())
        #expect(summary.contains("first sentence 2140ms"))
        #expect(summary.contains("synth 610ms"))
        #expect(summary.contains("first audio 2750ms"))
        #expect(summary.contains("answer 8900ms"))
    }

    @Test("the FIRST chunk and the FIRST audio own their marks — later ones only count")
    func firstMarksWin() throws {
        var timeline = VoiceTurnTimeline()
        timeline.endpointed(at: at(0))
        timeline.turnStarted(at: at(0))
        timeline.chunkReady(at: at(1000))
        timeline.chunkReady(at: at(4000))
        timeline.chunkReady(at: at(7000))
        timeline.audioStarted(at: at(1500))
        timeline.audioStarted(at: at(4500))
        timeline.completed(at: at(9000))

        let summary = try #require(timeline.summary())
        #expect(summary.contains("first sentence 1000ms"))
        #expect(summary.contains("first audio 1500ms"))
        #expect(summary.contains("3 sentences"))
    }

    @Test("audio before any sentence exists is a stale callback, not this turn's audio")
    func audioBeforeChunkIgnored() throws {
        // The reachable half of the PR #120 review race: a barged-in turn's TTS
        // tail fires its started-callback late, AFTER the flush — landing in
        // the next turn's timeline, where "first wins" would keep it forever.
        // Real audio can only follow this turn's first chunk (speak is only
        // enqueued once a sentence exists), so a mark with no chunk behind it
        // is provably not ours.
        var timeline = VoiceTurnTimeline()
        timeline.endpointed(at: at(0))
        timeline.turnStarted(at: at(10))
        timeline.audioStarted(at: at(20)) // stale tail from the previous turn
        timeline.chunkReady(at: at(500))
        timeline.audioStarted(at: at(1100)) // the real one

        timeline.completed(at: at(2000))
        let summary = try #require(timeline.summary())
        #expect(summary.contains("first audio 1100ms"), "stale mark won: \(summary)")
    }

    @Test("a stale audio mark cannot SETTLE a turn that hasn't spoken")
    func staleAudioDoesNotSettle() {
        // The worse half of the same bug: settled = completed + audio, so a
        // stale pre-chunk mark plus generation finishing would flush the turn
        // early — logged as spoken when nothing was ever heard.
        var timeline = VoiceTurnTimeline()
        timeline.endpointed(at: at(0))
        timeline.turnStarted(at: at(10))
        timeline.audioStarted(at: at(20)) // stale — no sentence exists
        timeline.completed(at: at(3000))
        #expect(!timeline.isSettled)
    }

    @Test("a turn that generated but never spoke says so instead of inventing a number")
    func noAudioIsNamed() throws {
        var timeline = VoiceTurnTimeline()
        timeline.endpointed(at: at(0))
        timeline.turnStarted(at: at(0))
        timeline.chunkReady(at: at(2000))
        timeline.completed(at: at(5000))

        let summary = try #require(timeline.summary())
        #expect(summary.contains("no audio"))
        #expect(!summary.contains("first audio"))
        #expect(summary.contains("answer 5000ms"))
    }

    @Test("a turn that produced nothing at all is still reported — that is the failure worth seeing")
    func emptyTurnStillReports() throws {
        var timeline = VoiceTurnTimeline()
        timeline.endpointed(at: at(0))
        timeline.turnStarted(at: at(0))
        timeline.completed(at: at(3000))

        let summary = try #require(timeline.summary())
        #expect(summary.contains("0 sentences"))
        #expect(summary.contains("answer 3000ms"))
    }

    @Test("an unfinished turn reports what it has — a barge-in must not lose the numbers")
    func unfinishedTurnReports() throws {
        var timeline = VoiceTurnTimeline()
        timeline.endpointed(at: at(0))
        timeline.turnStarted(at: at(0))
        timeline.chunkReady(at: at(1200))
        timeline.audioStarted(at: at(1700))

        let summary = try #require(timeline.summary())
        #expect(summary.contains("first audio 1700ms"))
        #expect(!summary.contains("answer "))
    }

    @Test("without an endpoint mark, latency is measured from the turn instead")
    func fallsBackToTurnStart() throws {
        // The typed/menu-bar path has no spoken endpoint. The numbers must still
        // mean something rather than silently reading as zero.
        var timeline = VoiceTurnTimeline()
        timeline.turnStarted(at: at(500))
        timeline.chunkReady(at: at(1500))
        timeline.audioStarted(at: at(2000))
        timeline.completed(at: at(3000))

        let summary = try #require(timeline.summary())
        #expect(summary.contains("first sentence 1000ms"))
        #expect(summary.contains("first audio 1500ms"))
        #expect(summary.contains("answer 2500ms"))
    }

    @Test("a turn settles only when BOTH generation and audio have landed")
    func settlesOnLastMark() {
        var timeline = VoiceTurnTimeline()
        #expect(!timeline.hasTurn)
        timeline.turnStarted(at: at(0))
        #expect(timeline.hasTurn)
        #expect(!timeline.isSettled)

        // Streaming shape: audio starts first, generation finishes later.
        timeline.chunkReady(at: at(1000))
        timeline.audioStarted(at: at(1400))
        #expect(!timeline.isSettled)
        timeline.completed(at: at(5000))
        #expect(timeline.isSettled)
    }

    @Test("generation finishing alone does not settle a turn that has not spoken yet")
    func completionAloneDoesNotSettle() {
        // The whole-answer shape: generation completes, THEN audio starts. A
        // settle-on-completion rule would report every one of those turns as
        // "no audio" and make the synth cost invisible.
        var timeline = VoiceTurnTimeline()
        timeline.turnStarted(at: at(0))
        timeline.completed(at: at(3000))
        #expect(!timeline.isSettled)
        timeline.chunkReady(at: at(3000))
        timeline.audioStarted(at: at(3600))
        #expect(timeline.isSettled)
    }

    @Test("each turn starts clean — a reset drops every mark")
    func resetClears() throws {
        var timeline = VoiceTurnTimeline()
        timeline.endpointed(at: at(0))
        timeline.turnStarted(at: at(0))
        timeline.chunkReady(at: at(1000))
        timeline.reset()
        #expect(timeline.summary() == nil)

        timeline.turnStarted(at: at(2000))
        timeline.chunkReady(at: at(2300))
        let summary = try #require(timeline.summary())
        #expect(summary.contains("first sentence 300ms"))
        #expect(summary.contains("1 sentence"))
    }
}
