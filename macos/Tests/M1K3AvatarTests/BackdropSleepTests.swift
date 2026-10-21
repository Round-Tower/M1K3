//
//  BackdropSleepTests.swift
//  M1K3AvatarTests
//
//  Pins when the chat backdrop may sleep (unmount). Measured 2026-10-21 on Kev's M1 Max,
//  chat window in front: the backdrop animating 46.5% CPU, paused 42.0%, absent 0.0%;
//  RealityKit's frame-rate SPI capped at 1 fps changed nothing. Only absence is cheap, so
//  an idle backdrop leaves, and comes back the moment anyone, or M1K3, does anything.
//

import Foundation
@testable import M1K3Avatar
import Testing

struct BackdropSleepTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test("idle M1K3, nobody typing, no input for the whole window → asleep")
    func sleepsAfterTheIdleWindow() {
        let now = t0.addingTimeInterval(BackdropSleep.idleAfter)
        #expect(BackdropSleep.isAsleep(activity: .idle, isTyping: false, lastInput: t0, now: now))
    }

    @Test("a second short of the window is still awake")
    func awakeJustBeforeTheWindow() {
        let now = t0.addingTimeInterval(BackdropSleep.idleAfter - 1)
        #expect(!BackdropSleep.isAsleep(activity: .idle, isTyping: false, lastInput: t0, now: now))
    }

    @Test("M1K3 doing anything keeps it awake, however long the user has been still")
    func activityKeepsItAwake() {
        let now = t0.addingTimeInterval(BackdropSleep.idleAfter * 10)
        for activity in AvatarActivity.allCases where activity.isActive {
            #expect(!BackdropSleep.isAsleep(activity: activity, isTyping: false, lastInput: t0, now: now))
        }
    }

    @Test("a draft in the composer keeps it awake")
    func typingKeepsItAwake() {
        let now = t0.addingTimeInterval(BackdropSleep.idleAfter * 10)
        #expect(!BackdropSleep.isAsleep(activity: .idle, isTyping: true, lastInput: t0, now: now))
    }

    @Test("an error face sleeps like idle: nothing is happening")
    func errorSleeps() {
        let now = t0.addingTimeInterval(BackdropSleep.idleAfter)
        #expect(BackdropSleep.isAsleep(activity: .error, isTyping: false, lastInput: t0, now: now))
    }

    @Test("the next check is the moment the window closes, never in the past")
    func nextCheck() {
        #expect(BackdropSleep.nextCheck(lastInput: t0, now: t0) == t0.addingTimeInterval(BackdropSleep.idleAfter))
        let late = t0.addingTimeInterval(BackdropSleep.idleAfter * 3)
        #expect(BackdropSleep.nextCheck(lastInput: t0, now: late) == late)
    }
}
