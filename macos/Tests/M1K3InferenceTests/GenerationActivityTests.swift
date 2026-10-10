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
//  Review: same day (pre-push review) — the options are `.userInitiatedAllowingIdleSystemSleep`;
//  cancellation and strict begin/end alternation pinned.
//  Review: Kev + claude-fable-5.1, 2026-10-09 — the `-generationActivity` kill-switch pinned
//  (reader parity; a disabled hold never begins).
//  Review: Kev + claude-fable-5.1, 2026-10-10 (#530) — the switch is read from the argument
//  domain only; a persisted key is pinned as ignored. Serialized: that domain is process-wide.

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

@Suite(.serialized) // the argument domain is process-wide
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
        // Strict alternation: never two begins (or two ends) in a row.
        for (a, b) in zip(calls, calls.dropFirst()) {
            #expect(a.hasPrefix("begin") != b.hasPrefix("begin"), "\(a) then \(b)")
        }
        #expect(calls.first?.hasPrefix("begin") == true)
        #expect(calls.last == "end")
        #expect(activity.holders == 0)
    }

    @Test("a cancelled turn ends the activity")
    func endsOnCancel() async {
        let asserter = RecordingAsserter()
        let activity = GenerationActivity(asserter: asserter)
        let task = Task {
            try await activity.during("stream") {
                try await Task.sleep(for: .seconds(60))
            }
        }
        while activity.holders == 0 {
            await Task.yield()
        }
        task.cancel()
        _ = await task.result
        #expect(asserter.calls == ["begin:stream", "end"])
        #expect(activity.holders == 0)
    }

    @Test("the shared instance opts out of App Nap and nothing else: display and idle system sleep stay the user's")
    func productionOptions() {
        // `.userInitiated` would ALSO disable idle system sleep (#PR-review 2026-10-07) — and
        // `caffeinate -is` already held that assertion overnight without stopping the stall, so
        // only the App Nap opt-out can be the lever. `.userInitiatedAllowingIdleSystemSleep` is it.
        #expect(ProcessActivityAsserter.options == .userInitiatedAllowingIdleSystemSleep)
        #expect(!ProcessActivityAsserter.options.contains(.idleSystemSleepDisabled))
        #expect(!ProcessActivityAsserter.options.contains(.idleDisplaySleepDisabled))
    }

    // MARK: - the -generationActivity kill-switch (the display-off A/B's arm B)

    @Test("the switch reads the way its words say: absent is on; NO / false / 0 are off")
    func switchParity() throws {
        let suite = "GenerationActivityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            defaults.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
        }
        #expect(GenerationActivity.isEnabled(in: defaults))
        for off in ["NO", "false", "0"] {
            defaults.setVolatileDomain([GenerationActivity.defaultsKey: off], forName: UserDefaults.argumentDomain)
            #expect(!GenerationActivity.isEnabled(in: defaults), "\(off)")
        }
        for on in ["YES", "true", "1"] {
            defaults.setVolatileDomain([GenerationActivity.defaultsKey: on], forName: UserDefaults.argumentDomain)
            #expect(GenerationActivity.isEnabled(in: defaults), "\(on)")
        }
    }

    @Test("a persisted key never turns the hold off: the switch is the launch argument only (#530)")
    func persistedKeyIsIgnored() throws {
        let suite = "GenerationActivityTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: GenerationActivity.defaultsKey)
        defaults.set("NO", forKey: GenerationActivity.defaultsKey)
        #expect(GenerationActivity.isEnabled(in: defaults))
    }

    @Test("a disabled hold never begins an activity, but still counts holders and runs the work")
    func disabledNeverBegins() async {
        let asserter = RecordingAsserter()
        let activity = GenerationActivity(asserter: asserter, enabled: false)
        let value = await activity.during("chat turn") {
            #expect(activity.holders == 1)
            return 7
        }
        #expect(value == 7)
        #expect(asserter.calls.isEmpty)
        #expect(activity.holders == 0)
    }
}
