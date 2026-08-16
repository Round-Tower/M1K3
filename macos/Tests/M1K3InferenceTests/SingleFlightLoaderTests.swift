//
//  SingleFlightLoaderTests.swift
//  M1K3InferenceTests
//
//  Contract tests for the single-flight async loader — the pure concurrency
//  primitive behind "don't download the ~1GB MLX container twice". The old
//  MLXGemmaProvider used a check-then-act NSLock: read the cache under the lock,
//  release it, then do the slow load with no lock held — so two concurrent
//  callers (a Settings preload racing the first generate) both saw nil and both
//  loaded. This actor makes concurrent callers share ONE load by construction,
//  and it's Metal-free, so the race fix is provable under `swift test`.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-08, Confidence 0.9, Prior: Unknown

import Foundation
@testable import M1K3Inference
import Testing

private actor InvocationCounter {
    private(set) var count = 0
    func bump() -> Int {
        count += 1
        return count
    }
}

private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func record(_ value: Double) {
        lock.withLock { values.append(value) }
    }

    var recorded: [Double] {
        lock.withLock { values }
    }
}

private enum LoaderTestError: Error { case boom }

/// A manually-opened latch: the loader operation parks on `wait()` until the
/// test calls `open()`, so cancellation promptness is proven by ORDER (the
/// waiter completes while the load is still parked), not by wall-clock timing.
private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        opened = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters = []
    }

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() {
        lock.withLock { value = true }
    }

    var isSet: Bool {
        lock.withLock { value }
    }
}

struct SingleFlightLoaderTests {
    @Test("concurrent callers share one load (the double-load race fix)")
    func concurrentCallersShareOneLoad() async throws {
        let counter = InvocationCounter()
        let loader = SingleFlightLoader<Int> { _ in
            _ = await counter.bump()
            try? await Task.sleep(for: .milliseconds(30))
            return 42
        }

        async let first = loader.value()
        async let second = loader.value()
        async let third = loader.value()
        let results = try await [first, second, third]

        #expect(results == [42, 42, 42])
        #expect(await counter.count == 1) // operation ran exactly once
    }

    @Test("a successful load is cached for later callers")
    func successIsCached() async throws {
        let counter = InvocationCounter()
        let loader = SingleFlightLoader<Int> { _ in
            _ = await counter.bump()
            return 7
        }

        _ = try await loader.value()
        _ = try await loader.value()
        _ = try await loader.value()

        #expect(await counter.count == 1)
    }

    @Test("a failed load clears the slot so a retry runs again")
    func failureAllowsRetry() async throws {
        let counter = InvocationCounter()
        let loader = SingleFlightLoader<Int> { _ in
            let attempt = await counter.bump()
            if attempt == 1 { throw LoaderTestError.boom }
            return 99
        }

        await #expect(throws: LoaderTestError.self) { _ = try await loader.value() }
        let retried = try await loader.value()

        #expect(retried == 99)
        #expect(await counter.count == 2) // failed once, then succeeded
    }

    @Test("progress from the operation reaches the caller's handler")
    func forwardsProgress() async throws {
        let collector = ProgressCollector()
        let loader = SingleFlightLoader<Int> { progress in
            progress(0.5)
            progress(1.0)
            return 1
        }

        _ = try await loader.value { collector.record($0) }

        #expect(collector.recorded == [0.5, 1.0])
    }

    @Test("a cancelled waiter does not spawn a duplicate load")
    func cancelledWaiterRejoinsInFlightLoad() async throws {
        let counter = InvocationCounter()
        let loader = SingleFlightLoader<Int> { _ in
            _ = await counter.bump()
            try? await Task.sleep(for: .milliseconds(50))
            return 1
        }

        // Start a load, let it begin, then cancel the waiting task. The underlying
        // load keeps running and the slot is kept, so the next caller rejoins it
        // rather than starting a second download.
        let first = Task { try await loader.value() }
        try? await Task.sleep(for: .milliseconds(10))
        first.cancel()
        _ = try? await first.value

        let result = try await loader.value()

        #expect(result == 1)
        #expect(await counter.count == 1) // still exactly one load, no duplicate
    }

    @Test("a cancelled waiter throws promptly instead of riding out the load")
    func cancelledWaiterThrowsPromptly() async throws {
        let gate = Gate()
        let counter = InvocationCounter()
        let finished = Flag()
        let loader = SingleFlightLoader<Int> { _ in
            _ = await counter.bump()
            await gate.wait() // parked until the test opens the gate
            return 1
        }

        let waiter = Task {
            defer { finished.set() }
            return try await loader.value()
        }
        while await counter.count == 0 {
            await Task.yield()
        } // flight underway
        waiter.cancel()

        // The waiter must complete WHILE the load is still parked on the gate —
        // that ordering, not wall-clock, is the promptness proof. The settle
        // beat only gives the cancellation handler time to run.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(finished.isSet, "cancelled waiter should not stay suspended behind the in-flight load")

        await gate.open() // release the flight either way so the test can't hang
        let outcome = await waiter.result
        #expect(throws: CancellationError.self) { _ = try outcome.get() }

        // The flight itself was NOT cancelled: a later caller rejoins its result.
        let value = try await loader.value()
        #expect(value == 1)
        #expect(await counter.count == 1)
    }

    @Test("a load that itself throws CancellationError clears the slot for retry")
    func operationCancellationErrorClearsSlot() async throws {
        let counter = InvocationCounter()
        let loader = SingleFlightLoader<Int> { _ in
            let attempt = await counter.bump()
            if attempt == 1 { throw CancellationError() }
            return 5
        }

        // A CancellationError thrown BY the operation is a load failure, not a
        // waiter cancel — it must clear the slot, or the loader is poisoned and
        // replays the stale error to every future caller with no retry path.
        await #expect(throws: CancellationError.self) { _ = try await loader.value() }
        let retried = try await loader.value()

        #expect(retried == 5)
        #expect(await counter.count == 2)
    }

    // MARK: - Eviction (2026-08-15, the deep-dive escalation's memory story)

    @Test("reset evicts the cached value so the next caller reloads")
    func resetEvictsCachedValue() async throws {
        // Until reset() existed, cachedValue lived for the loader's lifetime —
        // so "releasing" a parked MLXGemmaProvider freed its KV caches but
        // never its weights, and an escalated deep dive ran Big beside the
        // parked brain's resident weights (review catch, #130).
        let counter = InvocationCounter()
        let loader = SingleFlightLoader<Int> { _ in await counter.bump() }

        #expect(try await loader.value() == 1)
        #expect(try await loader.value() == 1) // cached
        await loader.reset()
        #expect(try await loader.value() == 2) // reloaded
        #expect(await counter.count == 2)
    }

    @Test("reset during an in-flight load leaves that flight to complete and re-cache")
    func resetDuringFlightIsDocumentedBehaviour() async throws {
        // Deliberate semantics: reset only evicts the CACHED value. An
        // in-flight load completes and caches its result — its waiters are owed
        // an answer, and tearing a live download out from under them is a
        // different (unneeded) feature. The dive's use runs reset on an IDLE
        // parked provider, so this branch is a documented edge, not the path.
        let gate = AsyncGate()
        let counter = InvocationCounter()
        let loader = SingleFlightLoader<Int> { _ in
            await gate.wait()
            return await counter.bump()
        }

        let inFlight = Task { try await loader.value() }
        try? await Task.sleep(for: .milliseconds(20)) // let the flight start
        await loader.reset()
        await gate.open()
        #expect(try await inFlight.value == 1)
        #expect(try await loader.value() == 1) // the completed flight re-cached
    }
}

/// Suspends waiters until opened — deterministic flight-in-progress control.
private actor AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        opened = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters.removeAll()
    }

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
