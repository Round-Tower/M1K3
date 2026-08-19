//
//  AskJobStoreTests.swift
//  M1K3MCPKitTests
//
//  The pure job lifecycle behind ask_m1k3's submit-and-poll path — driven with
//  an injected id generator + clock so it's deterministic and off-device.
//
//  Signed: Kev + claude-opus-4-8, 2026-07-01, Confidence 0.9, Prior: Unknown

import Foundation
@testable import M1K3MCPKit
import Testing

private func counterID() -> @Sendable () -> String {
    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var count = 0
    }
    let box = Box()
    return {
        box.lock.lock(); defer { box.lock.unlock() }
        box.count += 1
        return "job-\(box.count)"
    }
}

struct AskJobStoreTests {
    @Test("submit registers a running job and returns a fresh id")
    func submitRuns() async {
        let store = AskJobStore(makeID: counterID())
        let id = await store.submit()
        #expect(id == "job-1")
        #expect(await store.status(of: id) == .running)
    }

    @Test("distinct submits get distinct ids")
    func distinctIDs() async {
        let store = AskJobStore(makeID: counterID())
        let first = await store.submit()
        let second = await store.submit()
        #expect(first != second)
    }

    @Test("complete moves a running job to done")
    func completeDone() async {
        let store = AskJobStore(makeID: counterID())
        let id = await store.submit()
        await store.complete(id: id, result: "the answer")
        #expect(await store.status(of: id) == .done("the answer"))
    }

    @Test("fail moves a running job to error")
    func failError() async {
        let store = AskJobStore(makeID: counterID())
        let id = await store.submit()
        await store.fail(id: id, message: "brain busy")
        #expect(await store.status(of: id) == .error("brain busy"))
    }

    @Test("an unknown id has no status")
    func unknownIsNil() async {
        let store = AskJobStore(makeID: counterID())
        #expect(await store.status(of: "nope") == nil)
    }

    @Test("complete on an unknown id is a safe no-op")
    func completeUnknownNoOp() async {
        let store = AskJobStore(makeID: counterID())
        await store.complete(id: "ghost", result: "x")
        #expect(await store.status(of: "ghost") == nil)
    }

    @Test("a late completion cannot clobber a terminal (failed) job")
    func terminalStateIsSticky() async {
        let store = AskJobStore(makeID: counterID())
        let id = await store.submit()
        await store.fail(id: id, message: "timed out")
        await store.complete(id: id, result: "arrived too late")
        #expect(await store.status(of: id) == .error("timed out"))
    }

    @Test("runningJobIDs lists only running jobs, oldest first")
    func runningJobIDsOldestFirst() async {
        let store = AskJobStore(makeID: counterID())
        let first = await store.submit()
        let done = await store.submit()
        await store.complete(id: done, result: "answered")
        let second = await store.submit()
        #expect(await store.runningJobIDs() == [first, second])
    }

    @Test("summaries carry id, state, and age — never the answer text")
    func summariesShape() async {
        // Advancing clock: submit at t0, finish + read 30s later.
        final class ClockBox: @unchecked Sendable {
            private let lock = NSLock()
            private var now = Date(timeIntervalSince1970: 1_000_000)
            func advance(_ seconds: TimeInterval) {
                lock.lock(); now = now.addingTimeInterval(seconds); lock.unlock()
            }

            func read() -> Date {
                lock.lock(); defer { lock.unlock() }
                return now
            }
        }
        let clock = ClockBox()
        let store = AskJobStore(makeID: counterID(), now: { clock.read() })
        let running = await store.submit()
        let finished = await store.submit()
        clock.advance(30)
        await store.complete(id: finished, result: "the secret answer text")
        let failed = await store.submit()
        await store.fail(id: failed, message: "brain busy")

        let summaries = await store.summaries()
        #expect(summaries.count == 3)
        // Newest submission first — the recovery listing leads with what the
        // caller most recently fired.
        #expect(summaries.map(\.id) == [failed, finished, running])
        #expect(summaries.first { $0.id == running }?.state == "running")
        #expect(summaries.first { $0.id == finished }?.state == "done")
        #expect(summaries.first { $0.id == failed }?.state == "error")
        #expect(summaries.first { $0.id == running }?.ageSeconds == 30)
        #expect(summaries.first { $0.id == failed }?.ageSeconds == 0)
        // Structural: a summary has no payload field — the answer text can't leak
        // through list_jobs. Pinned via the debug rendering of the whole value.
        #expect(!String(describing: summaries).contains("secret answer"))
    }

    @Test("reap evicts a terminal job past the ttl but keeps running + fresh jobs")
    func reaping() async {
        // Frozen clock so finishedAt and the reap cutoff are deterministic.
        let epoch = Date(timeIntervalSince1970: 1_000_000)
        let store = AskJobStore(makeID: counterID(), now: { epoch })

        let stale = await store.submit()
        await store.complete(id: stale, result: "old") // finishedAt = epoch
        let running = await store.submit() // still running
        let fresh = await store.submit()
        await store.complete(id: fresh, result: "new") // finishedAt = epoch

        // ttl=0 with a frozen clock: cutoff == epoch, so a job finished AT epoch
        // is not strictly after the cutoff → the terminal ones are evicted, the
        // running one survives.
        let removed = await store.reap(olderThan: 0)
        #expect(removed == 2)
        #expect(await store.status(of: stale) == nil)
        #expect(await store.status(of: fresh) == nil)
        #expect(await store.status(of: running) == .running)
    }
}
