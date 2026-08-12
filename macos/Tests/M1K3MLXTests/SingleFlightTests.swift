//
//  SingleFlightTests.swift
//  M1K3MLXTests
//
//  Signed: Kev + claude-opus-5, 2026-08-09, Confidence 0.9. Prior: Unknown
//

import Foundation
@testable import M1K3MLX
import Testing

/// Counts calls across concurrent callers.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0
    func bump() {
        lock.lock(); count += 1; lock.unlock()
    }
}

struct SingleFlightTests {
    /// THE bug, in miniature. On the live app several callers asked for the
    /// same persona prefix at once, all missed the cache because nobody had
    /// stored yet, and each paid a ~13-second prefill. Every one of them
    /// should have been waiting on the first.
    @Test("concurrent callers on one key run the work once and all get the result")
    func concurrentCallersCoalesce() async throws {
        let flight = SingleFlight<String, Int>()
        let calls = Counter()

        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    try await flight.run("persona") {
                        calls.bump()
                        // Long enough that every caller arrives before it finishes —
                        // the shape that made the real cache useless.
                        try await Task.sleep(for: .milliseconds(120))
                        return 1991
                    }
                }
            }
            return try await group.reduce(into: [Int]()) { $0.append($1) }
        }

        #expect(calls.count == 1, "the work must run once, not once per caller")
        #expect(results == Array(repeating: 1991, count: 8))
    }

    @Test("different keys are not coalesced — a second palette is genuinely different work")
    func differentKeysRunSeparately() async throws {
        let flight = SingleFlight<String, Int>()
        let calls = Counter()
        async let a = flight.run("with-tools") { calls.bump(); return 1 }
        async let b = flight.run("no-tools") { calls.bump(); return 2 }
        _ = try await (a, b)
        #expect(calls.count == 2)
    }

    @Test("a sequential caller after completion starts fresh — this coalesces, it does not cache")
    func sequentialCallsAreNotCached() async throws {
        let flight = SingleFlight<String, Int>()
        let calls = Counter()
        _ = try await flight.run("k") { calls.bump(); return 1 }
        _ = try await flight.run("k") { calls.bump(); return 1 }
        #expect(calls.count == 2)
        #expect(await flight.busyKeys.isEmpty)
    }

    /// A thrown build must not be inherited by everyone who comes later — the
    /// prefix build is best-effort and the next turn should be free to retry.
    @Test("a failure clears the slot instead of being cached")
    func failureIsNotSticky() async {
        struct Boom: Error {}
        let flight = SingleFlight<String, Int>()
        await #expect(throws: Boom.self) { try await flight.run("k") { throw Boom() } }
        let recovered = try? await flight.run("k") { 7 }
        #expect(recovered == 7)
        #expect(await flight.busyKeys.isEmpty)
    }
}
