//
//  HeartbeatHoldLineTests.swift
//  M1K3HeartbeatTests
//
//  Pins the honest-hold resolver: when the latest pulse goes stale, the
//  surfaces say WHY (quiet hours / warm machine / busy / quiet stretch)
//  instead of showing an ageing timestamp that reads as "the heartbeat is
//  broken" — the 2026-08-08 live finding: 3 thermal skips and 47 quiet-hour
//  skips in one night, every one of them invisible in the UI.
//
//  Signed: Kev + claude-fable-5, 2026-08-08, Confidence 0.9 (pure resolver,
//  every branch pinned red-first). Prior: none (new file).
//

import Foundation
@testable import M1K3Heartbeat
import Testing

struct HeartbeatHoldLineTests {
    private let noon = Date(timeIntervalSince1970: 1_754_480_000)

    private func resolve(
        hour: Int = 12,
        lastPulse: Date?,
        lastHold: HeartbeatHold?
    ) -> String? {
        HeartbeatHoldLine.resolve(
            now: noon, hour: hour, lastPulse: lastPulse, lastHold: lastHold
        )
    }

    @Test("a fresh pulse needs no hold line")
    func freshPulseIsSilent() {
        let line = resolve(lastPulse: noon.addingTimeInterval(-60 * 60), lastHold: nil)
        #expect(line == nil)
    }

    @Test("a fresh pulse wins even over a recent hold")
    func freshPulseBeatsHold() {
        let hold = HeartbeatHold(reason: .thermal, at: noon.addingTimeInterval(-5 * 60))
        let line = resolve(lastPulse: noon.addingTimeInterval(-60 * 60), lastHold: hold)
        #expect(line == nil)
    }

    @Test("stale inside quiet hours explains the night")
    func quietHoursExplains() {
        let line = resolve(
            hour: 3,
            lastPulse: noon.addingTimeInterval(-6 * 60 * 60),
            lastHold: HeartbeatHold(reason: .quietHours, at: noon.addingTimeInterval(-5 * 60))
        )
        #expect(line == "Quiet hours — the next pulse comes with the morning.")
    }

    @Test("stale with a recent thermal hold names the warmth")
    func thermalHoldExplains() {
        let hold = HeartbeatHold(reason: .thermal, at: noon.addingTimeInterval(-10 * 60))
        let line = resolve(lastPulse: noon.addingTimeInterval(-3 * 60 * 60), lastHold: hold)
        #expect(line == "Holding off while the machine runs warm.")
    }

    @Test("stale with a recent busy hold names the busyness")
    func busyHoldExplains() {
        let hold = HeartbeatHold(reason: .machineBusy, at: noon.addingTimeInterval(-10 * 60))
        let line = resolve(lastPulse: noon.addingTimeInterval(-3 * 60 * 60), lastHold: hold)
        #expect(line == "Holding off while the machine is busy.")
    }

    @Test("stale with a recent quiet-window withhold owns the quiet")
    func quietWindowExplains() {
        let hold = HeartbeatHold(reason: .quietWindow, at: noon.addingTimeInterval(-10 * 60))
        let line = resolve(lastPulse: noon.addingTimeInterval(-3 * 60 * 60), lastHold: hold)
        #expect(line == "A quiet stretch — I'll pulse when something happens, or with the morning.")
    }

    @Test("a stale hold (loop gone quiet, e.g. the machine slept) says nothing")
    func staleHoldIsSilent() {
        let hold = HeartbeatHold(reason: .thermal, at: noon.addingTimeInterval(-2 * 60 * 60))
        let line = resolve(lastPulse: noon.addingTimeInterval(-5 * 60 * 60), lastHold: hold)
        #expect(line == nil)
    }

    @Test("a leftover quiet-hours hold in the daytime is silent — the loop fires within minutes")
    func daytimeQuietHoursHoldIsSilent() {
        let hold = HeartbeatHold(reason: .quietHours, at: noon.addingTimeInterval(-10 * 60))
        let line = resolve(lastPulse: noon.addingTimeInterval(-10 * 60 * 60), lastHold: hold)
        #expect(line == nil)
    }

    @Test("no pulse ever, daytime, no hold: the first pulse is coming")
    func firstPulseAnnounced() {
        let line = resolve(lastPulse: nil, lastHold: nil)
        #expect(line == "The first pulse is on its way.")
    }

    @Test("no pulse ever inside quiet hours still explains the night first")
    func firstPulseDefersToQuietHours() {
        let line = resolve(hour: 23, lastPulse: nil, lastHold: nil)
        #expect(line == "Quiet hours — the next pulse comes with the morning.")
    }

    @Test("stale pulse with no hold information stays silent")
    func staleWithoutHoldIsSilent() {
        let line = resolve(lastPulse: noon.addingTimeInterval(-5 * 60 * 60), lastHold: nil)
        #expect(line == nil)
    }

    @Test("the staleness slack keeps the line quiet just past the interval")
    func slackBoundary() {
        let hold = HeartbeatHold(reason: .thermal, at: noon.addingTimeInterval(-5 * 60))
        let justInside = resolve(
            lastPulse: noon.addingTimeInterval(-(2 * 60 * 60 + 20 * 60)), lastHold: hold
        )
        #expect(justInside == nil)
        let justOutside = resolve(
            lastPulse: noon.addingTimeInterval(-(2 * 60 * 60 + 40 * 60)), lastHold: hold
        )
        #expect(justOutside == "Holding off while the machine runs warm.")
    }

    @Test("a future-dated pulse (clock skew) reads as fresh, not stale")
    func futurePulseIsFresh() {
        let hold = HeartbeatHold(reason: .thermal, at: noon.addingTimeInterval(-5 * 60))
        let line = resolve(lastPulse: noon.addingTimeInterval(60 * 60), lastHold: hold)
        #expect(line == nil)
    }

    @Test("skip reasons map to hold reasons; tooSoon maps to none")
    func skipReasonMapping() {
        #expect(HeartbeatHoldReason(skip: .tooSoon) == nil)
        #expect(HeartbeatHoldReason(skip: .quietHours) == .quietHours)
        #expect(HeartbeatHoldReason(skip: .machineBusy) == .machineBusy)
        #expect(HeartbeatHoldReason(skip: .thermal) == .thermal)
    }
}
