//
//  HeartbeatSchedulePolicyTests.swift
//  M1K3HeartbeatTests
//
//  Pins the pure pulse-scheduling decision: when a heartbeat fires and, when
//  it doesn't, WHICH reason wins (quiet hours before cadence before busy
//  before thermal — cheapest check first, and the skip reason is what the
//  log line carries).
//
//  Signed: Kev + claude-fable-5, 2026-08-06, Confidence 0.9 (pure policy,
//  every branch pinned red-first). Prior: none (new file).
//

import Foundation
@testable import M1K3Heartbeat
import Testing

struct HeartbeatSchedulePolicyTests {
    private let policy = HeartbeatSchedulePolicy()
    private let noon = Date(timeIntervalSince1970: 1_754_480_000)

    @Test("first pulse (no watermark) fires immediately outside quiet hours")
    func firstPulseFires() {
        let decision = policy.decide(
            now: noon, hour: 12, lastPulse: nil, isBusy: false, backgroundAllowed: true
        )
        #expect(decision == .fire)
    }

    @Test("a pulse inside the interval is tooSoon")
    func withinIntervalSkips() {
        let lastPulse = noon.addingTimeInterval(-30 * 60)
        let decision = policy.decide(
            now: noon, hour: 12, lastPulse: lastPulse, isBusy: false, backgroundAllowed: true
        )
        #expect(decision == .skip(.tooSoon))
    }

    @Test("a pulse past the interval fires")
    func pastIntervalFires() {
        let lastPulse = noon.addingTimeInterval(-policy.interval - 1)
        let decision = policy.decide(
            now: noon, hour: 12, lastPulse: lastPulse, isBusy: false, backgroundAllowed: true
        )
        #expect(decision == .fire)
    }

    @Test("quiet hours win over everything, even a due first pulse")
    func quietHoursWin() {
        let decision = policy.decide(
            now: noon, hour: 2, lastPulse: nil, isBusy: true, backgroundAllowed: false
        )
        #expect(decision == .skip(.quietHours))
    }

    @Test("a busy machine skips a due pulse — never a second decode loop")
    func busySkips() {
        let decision = policy.decide(
            now: noon, hour: 12, lastPulse: nil, isBusy: true, backgroundAllowed: true
        )
        #expect(decision == .skip(.machineBusy))
    }

    @Test("thermal/low-power pressure skips a due pulse")
    func thermalSkips() {
        let decision = policy.decide(
            now: noon, hour: 12, lastPulse: nil, isBusy: false, backgroundAllowed: false
        )
        #expect(decision == .skip(.thermal))
    }

    @Test("busy is reported before thermal when both hold")
    func busyBeforeThermal() {
        let decision = policy.decide(
            now: noon, hour: 12, lastPulse: nil, isBusy: true, backgroundAllowed: false
        )
        #expect(decision == .skip(.machineBusy))
    }

    @Test("a future watermark (clock skew) clamps to due-now instead of wedging")
    func futureWatermarkClamps() {
        let lastPulse = noon.addingTimeInterval(3600)
        let decision = policy.decide(
            now: noon, hour: 12, lastPulse: lastPulse, isBusy: false, backgroundAllowed: true
        )
        #expect(decision == .fire)
    }

    @Test("default cadence is two hours")
    func defaultInterval() {
        #expect(policy.interval == 2 * 60 * 60)
    }
}

struct QuietHoursTests {
    @Test("standard quiet hours span midnight: 23:00 through 07:59")
    func spansMidnight() {
        let quiet = QuietHours.standard
        #expect(quiet.contains(hour: 23))
        #expect(quiet.contains(hour: 0))
        #expect(quiet.contains(hour: 7))
        #expect(!quiet.contains(hour: 8))
        #expect(!quiet.contains(hour: 12))
        #expect(!quiet.contains(hour: 22))
    }

    @Test("a non-wrapping window behaves as a plain half-open range")
    func plainRange() {
        let quiet = QuietHours(startHour: 1, endHour: 5)
        #expect(quiet.contains(hour: 1))
        #expect(quiet.contains(hour: 4))
        #expect(!quiet.contains(hour: 5))
        #expect(!quiet.contains(hour: 0))
    }

    @Test("start == end means never quiet")
    func degenerateWindowNeverQuiet() {
        let quiet = QuietHours(startHour: 9, endHour: 9)
        for hour in 0 ..< 24 {
            #expect(!quiet.contains(hour: hour))
        }
    }
}
