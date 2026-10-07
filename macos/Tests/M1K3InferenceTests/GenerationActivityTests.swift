//
//  GenerationActivityTests.swift
//  M1K3InferenceTests
//
//  Pins the process-activity hold that keeps macOS from throttling M1K3 while it
//  generates with the display asleep (2026-10-07: the overnight bake-off's decode fell
//  35 → 0–3 tok/s within minutes of display-off, and recovered ten seconds after wake).
//  Reference-counted: overlapping turns share ONE assertion, and the last one out ends it.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-07, Confidence 0.85, Prior: none (new file).

import Foundation
@testable import M1K3Inference
import Synchronization
import Testing

/// Records begin/end calls instead of touching ProcessInfo.
final class RecordingAsserter: ActivityAsserting, Sendable {
    let log = Mutex<[String]>([])
    func begin(reason: String) -> ActivityToken {
        log.withLock { $0.append("begin:\(reason)") }
        return ActivityToken(NSObject())
    }

    func end(_: ActivityToken) {
        log.withLock { $0.append("end") }
    }

    var calls: [String] {
        log.withLock { $0 }
    }
}

struct GenerationActivityTests {
    @Test("one hold begins one activity and ends it when the work returns")
    func singleHold() async {
        let asserter = RecordingAsserter()
        let activity = GenerationActivity(asserter: asserter)
        let value = await activity.during("chat turn") { 42 }
        #expect(value == 42)
        #expect(asserter.calls == ["begin:chat turn", "end"])
        #expect(activity.holders == 0)
    }

    @Test("a throwing turn still ends the activity")
    func endsOnThrow() async {
        struct Boom: Error {}
        let asserter = RecordingAsserter()
        let activity = GenerationActivity(asserter: asserter)
        await #expect(throws: Boom.self) {
            try await activity.during("tool step") { throw Boom() }
        }
        #expect(asserter.calls == ["begin:tool step", "end"])
        #expect(activity.holders == 0)
    }

    @Test("overlapping holds share one assertion; the last one out ends it")
    func nestedHoldsShareOne() async {
        let asserter = RecordingAsserter()
        let activity = GenerationActivity(asserter: asserter)
        await activity.during("outer") {
            await activity.during("inner") {
                #expect(activity.holders == 2)
            }
            #expect(activity.holders == 1)
            #expect(asserter.calls == ["begin:outer"])
        }
        #expect(asserter.calls == ["begin:outer", "end"])
    }

    @Test("concurrent turns never double-begin or leak an assertion")
    func concurrentHolds() async {
        let asserter = RecordingAsserter()
        let activity = GenerationActivity(asserter: asserter)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 50 {
                group.addTask { await activity.during("mcp ask") { await Task.yield() } }
            }
        }
        let calls = asserter.calls
        #expect(calls.count(where: { $0.hasPrefix("begin") }) == calls.count(where: { $0 == "end" }))
        #expect(calls.last == "end")
        #expect(activity.holders == 0)
    }

    @Test("the shared instance asks for user-initiated work, never display or system sleep prevention")
    func productionOptions() {
        // .userInitiated opts out of App Nap — what the throttling needed. The display may
        // still sleep (that is the user's setting), and so may the system when idle.
        #expect(ProcessActivityAsserter.options.contains(.userInitiated))
        #expect(!ProcessActivityAsserter.options.contains(.idleDisplaySleepDisabled))
    }
}
