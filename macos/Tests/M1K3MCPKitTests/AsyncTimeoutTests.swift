//
//  AsyncTimeoutTests.swift
//  M1K3MCPKitTests
//
//  The deadline behind ask_m1k3's single-flight lock (test-report F1): a slow
//  operation is cancelled and surfaces TimeoutError; a quick one passes
//  through; an operation's own error wins over the clock.
//

import Foundation
@testable import M1K3MCPKit
import Synchronization
import Testing

struct AsyncTimeoutTests {
    @Test("an operation that finishes in time returns its value")
    func completesInTime() async throws {
        let value = try await withTimeout(seconds: 5) {
            try await Task.sleep(for: .milliseconds(10))
            return 42
        }
        #expect(value == 42)
    }

    @Test("an operation that outlives the deadline throws TimeoutError, fast")
    func timesOut() async {
        let start = ContinuousClock.now
        await #expect(throws: TimeoutError.self) {
            _ = try await withTimeout(seconds: 0.1) {
                try await Task.sleep(for: .seconds(60)) // far past the deadline
                return "should never arrive"
            }
        }
        // TimeoutError itself proves the deadline branch won the race. The
        // clock bound only guards "blocked for the full 60s operation", kept
        // at half the operation because tight bounds flake on stalled CI
        // runners (a 5s bound measured 9.5s for a 0.1s deadline return —
        // the runner stalled, not the code).
        #expect(start.duration(to: .now) < .seconds(30))
    }

    @Test("timing out cancels the operation")
    func cancelsTheLoser() async {
        let cancelled = Mutex(false)
        await #expect(throws: TimeoutError.self) {
            _ = try await withTimeout(seconds: 0.1) {
                await withTaskCancellationHandler {
                    try? await Task.sleep(for: .seconds(10))
                } onCancel: {
                    cancelled.withLock { $0 = true }
                }
                return "done"
            }
        }
        // The loser's cancel handler runs when that task is scheduled: on a starved CI runner
        // the 0.1 s deadline can fire before the operation even starts, so the handler lands
        // just AFTER the throw (#598's run: a 23 s stall). Wait for it; 30 s separates the
        // two outcomes (tools/ci/check_wall_clock_bounds.py's floor).
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !cancelled.withLock({ $0 }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(cancelled.withLock { $0 } == true)
    }

    @Test("the operation's own error wins over the clock")
    func operationErrorPropagates() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            _ = try await withTimeout(seconds: 5) {
                throw Boom()
            }
        }
    }
}
