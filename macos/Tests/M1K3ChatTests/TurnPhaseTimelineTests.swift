//
//  TurnPhaseTimelineTests.swift
//  M1K3ChatTests
//
//  The pre-generation instrument. The 2026-08-10 live-path eval found 177
//  seconds of TOTAL log silence before a turn's first model call — the largest
//  single latency contributor was invisible, because "turn start:" only logs
//  AFTER retrieval. This timeline names every phase the responder owns before
//  generation (embed / retrieve / cap / handoff) so the next slow turn says
//  where the time went. Pure and clock-injected, the VoiceTurnTimeline
//  precedent: marks take instants from the caller, arithmetic pinned with no
//  sleeping.
//
//  Signed: Kev + claude-fable-5, 2026-08-16, Confidence 0.9 (pure arithmetic,
//  red-first; the responder wiring is exercised at every real turn). Prior: Unknown.
//

import M1K3Chat
import Testing

struct TurnPhaseTimelineTests {
    private let base = ContinuousClock().now

    private func at(_ ms: Int) -> ContinuousClock.Instant {
        base.advanced(by: .milliseconds(ms))
    }

    @Test("a full retrieval turn names every phase and the total")
    func fullTurn() throws {
        var timeline = TurnPhaseTimeline()
        timeline.started(at: at(0))
        timeline.embedded(at: at(4012))
        timeline.retrieved(at: at(4101))
        timeline.capped(at: at(4104))
        timeline.handedOff(at: at(4105))

        let summary = try #require(timeline.summary(gate: .normal))
        #expect(summary.contains("embed 4012ms"))
        #expect(summary.contains("retrieve 89ms"))
        #expect(summary.contains("cap 3ms"))
        #expect(summary.contains("pre-gen 4105ms"))
        #expect(summary.contains("gate=normal"))
    }

    @Test("a self-query turn omits the phases it skipped")
    func selfQueryTurn() throws {
        var timeline = TurnPhaseTimeline()
        timeline.started(at: at(0))
        timeline.capped(at: at(2))
        timeline.handedOff(at: at(3))

        let summary = try #require(timeline.summary(gate: .selfQuery))
        #expect(!summary.contains("embed"))
        #expect(!summary.contains("retrieve"))
        #expect(summary.contains("pre-gen 3ms"))
        #expect(summary.contains("gate=self-query"))
    }

    @Test("no start, no summary — a never-started timeline stays silent")
    func neverStarted() {
        let timeline = TurnPhaseTimeline()
        #expect(timeline.summary(gate: .normal) == nil)
    }

    @Test("a started-but-unfinished turn still reports what it has")
    func unfinished() throws {
        // The turn that HANGS is exactly the one whose phases matter most —
        // if embed blocked for minutes, the marks up to the block must not be
        // held hostage by the missing handoff.
        var timeline = TurnPhaseTimeline()
        timeline.started(at: at(0))
        timeline.embedded(at: at(177_000))

        let summary = try #require(timeline.summary(gate: .normal))
        #expect(summary.contains("embed 177000ms"))
        #expect(!summary.contains("pre-gen"))
    }
}
