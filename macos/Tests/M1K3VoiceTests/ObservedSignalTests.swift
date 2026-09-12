//
//  ObservedSignalTests.swift
//  M1K3VoiceTests
//
//  `ObservedSignal.waitForChange` — the notch HUD's wait-on-the-speech-signal
//  (#293): resumes on the observed change, on the valve, or on cancellation,
//  exactly once, whichever comes first. Pinned here instead of by launch
//  because three review passes each found a race in the app-target original.
//  No elapsed-time assertions: completion IS the pass; a hang is the failure,
//  bounded by the suite's time limit (the #280 rule).
//
//  Signed: Kev + claude-fable-5.1, 2026-09-12, Confidence 0.85, Prior: Unknown.
//

import Foundation
@testable import M1K3Voice
import Observation
import Testing

@Observable @MainActor
private final class Flag {
    var on = false
}

@MainActor
private final class Probe {
    var armed = false
}

@MainActor
struct ObservedSignalTests {
    /// Start a wait on `flag` and return once its read has run (the wait is armed).
    private func armedWait(_ flag: Flag, valve: Duration) async -> Task<Void, Never> {
        let probe = Probe()
        let task = Task { @MainActor in
            await ObservedSignal.waitForChange(valve: valve) {
                probe.armed = true
                _ = flag.on
            }
        }
        while !probe.armed {
            await Task.yield()
        }
        return task
    }

    @Test("a change to the observed read resumes the wait", .timeLimit(.minutes(1)))
    func changeResumes() async {
        let flag = Flag()
        let task = await armedWait(flag, valve: .seconds(60))
        flag.on = true
        await task.value
        #expect(!task.isCancelled)
    }

    @Test("the valve resumes a wait nothing else touched", .timeLimit(.minutes(1)))
    func valveResumes() async {
        let flag = Flag()
        let task = await armedWait(flag, valve: .milliseconds(20))
        await task.value
        #expect(!flag.on)
    }

    @Test("cancelling the waiting task resumes it at once", .timeLimit(.minutes(1)))
    func cancellationResumes() async {
        let flag = Flag()
        let task = await armedWait(flag, valve: .seconds(60))
        task.cancel()
        await task.value
        #expect(task.isCancelled)
    }

    @Test("a task cancelled before the wait arms never suspends on it", .timeLimit(.minutes(1)))
    func cancelledBeforeArming() async {
        let flag = Flag()
        let task = Task { @MainActor in
            await ObservedSignal.waitForChange(valve: .seconds(60)) { _ = flag.on }
        }
        task.cancel()
        await task.value
        #expect(task.isCancelled)
    }

    @Test("change, valve and cancel racing resume exactly once — no double-resume trap", .timeLimit(.minutes(1)))
    func resumesOnce() async {
        let flag = Flag()
        let task = await armedWait(flag, valve: .milliseconds(1))
        flag.on = true
        task.cancel()
        await task.value
        flag.on = false // a later change finds nothing to resume
        #expect(task.isCancelled)
    }
}
