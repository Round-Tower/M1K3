//
//  LookCameraLifecycleTests.swift
//  M1K3ChatTests
//
//  The camera's on/off rules against a fake worker with gates (#768). Each
//  test holds the open at one of its two awaits (the permission ask, the
//  session start), acts, lets go, and reads whether the worker is running. The
//  fake models the real worker's ordering hazard: a stop that lands before a
//  start still in flight leaves the camera ON unless the lifecycle stops it
//  again.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-09, Confidence 0.85, Prior: none (new file)
//  Context: both pre-push reviews named the race: "The camera can stay on with
//  no screen after a close during the permission await".
//  Review: Kev + claude-fable-5.2, 2026-11-09 — `closeBeforeTheOpenBegins`, the
//  sequence the iPhone re-drill caught (open and close in one breath left the
//  state at `opening`). No gate reaches the gap before the open's task first
//  runs, so it is a 500-round race that accepts every legal ending and only
//  those: red 2 rounds in 200 on the old rules, never red on the new.
//

import Foundation
@testable import M1K3Chat
import Synchronization
import Testing

/// A door a fake waits at. `arrivals` says how many have reached it; `release`
/// lets the ones waiting through and leaves the door shut for the next.
private final class Gate: Sendable {
    private struct Box {
        var waiting: [CheckedContinuation<Void, Never>] = []
        var arrivals = 0
        var alwaysOpen = false
    }

    private let box = Mutex(Box())

    init(open: Bool = false) {
        box.withLock { $0.alwaysOpen = open }
    }

    var arrivals: Int {
        box.withLock { $0.arrivals }
    }

    func wait() async {
        await withCheckedContinuation { waiter in
            let through = box.withLock { box -> Bool in
                box.arrivals += 1
                if box.alwaysOpen { return true }
                box.waiting.append(waiter)
                return false
            }
            if through { waiter.resume() }
        }
    }

    func release() {
        let waiting = box.withLock { box in
            defer { box.waiting = [] }
            return box.waiting
        }
        for waiter in waiting {
            waiter.resume()
        }
    }
}

/// The worker a lifecycle drives, faked: `running` is what the green dot would show.
private final class FakeWorker: Sendable {
    private struct Box {
        var running = false
        var starts = 0
        var stops = 0
        var access = LookCameraLifecycle.Access.granted
        var startSucceeds = true
    }

    let accessGate: Gate
    let startGate: Gate
    private let box = Mutex(Box())

    init(accessGated: Bool = false, startGated: Bool = false) {
        accessGate = Gate(open: !accessGated)
        startGate = Gate(open: !startGated)
    }

    var running: Bool {
        box.withLock { $0.running }
    }

    var starts: Int {
        box.withLock { $0.starts }
    }

    var stops: Int {
        box.withLock { $0.stops }
    }

    func set(access: LookCameraLifecycle.Access) {
        box.withLock { $0.access = access }
    }

    func setStartSucceeds(_ value: Bool) {
        box.withLock { $0.startSucceeds = value }
    }

    @MainActor
    func lifecycle(hasCamera: Bool = true) -> LookCameraLifecycle {
        LookCameraLifecycle(
            hasCamera: { hasCamera },
            access: { [self] in
                await accessGate.wait()
                return box.withLock { $0.access }
            },
            start: { [self] in
                await startGate.wait()
                return box.withLock { box in
                    box.starts += 1
                    box.running = box.startSucceeds
                    return box.running
                }
            },
            stop: { [self] in
                box.withLock { box in
                    box.stops += 1
                    box.running = false
                }
            }
        )
    }
}

@MainActor
struct LookCameraLifecycleTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 3000 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }

    @Test("an open with permission ends open and running")
    func opens() async {
        let worker = FakeWorker()
        let camera = worker.lifecycle()
        #expect(await camera.open())
        #expect(camera.state == .open)
        #expect(camera.isOpen && camera.isOn)
        #expect(worker.running)
        camera.close()
        #expect(camera.state == .closed)
        #expect(!worker.running)
    }

    @Test("a close that lands before the open has begun leaves nothing behind, not even a spinner")
    func closeBeforeTheOpenBegins() async {
        // Found on the iPhone (the 2026-11-09 re-drill): open and close in the
        // same breath left the state at `opening` for good, with no camera on.
        // The sequence is the drill's, to the letter. Run many times: which
        // side of the first hop the close lands on is the scheduler's choice,
        // and every landing must end closed.
        for _ in 0 ..< 500 {
            let worker = FakeWorker()
            let camera = worker.lifecycle()
            let opening = Task { await camera.open() }
            await Task.yield()
            let finishedFirst = camera.state == .open
            camera.close()
            #expect(camera.state == .closed)
            let opened = await opening.value
            // Whichever side of the close the open landed on, it has now ended
            // one of three ways: it finished first and the close shut it; it
            // began after the close, so it is the newest word and stands; or
            // it was overtaken and nothing is on. Never in between.
            if finishedFirst {
                #expect(opened)
                #expect(camera.state == .closed)
                #expect(!worker.running)
            } else if opened {
                #expect(camera.state == .open)
                #expect(worker.running)
            } else {
                #expect(camera.state == .closed, "a dead open left the state at \(camera.state)")
                #expect(!camera.isOn)
                #expect(!worker.running)
            }
            camera.close()
            #expect(camera.state == .closed)
        }
    }

    @Test("a close while iOS is still asking for permission never starts the camera")
    func closeDuringThePermissionAsk() async throws {
        let worker = FakeWorker(accessGated: true)
        let camera = worker.lifecycle()
        let opening = Task { await camera.open() }
        try await waitUntil { worker.accessGate.arrivals == 1 }
        #expect(camera.state == .opening)
        #expect(camera.isOn && !camera.isOpen)

        camera.close()
        #expect(camera.state == .closed)
        worker.accessGate.release()

        #expect(await opening.value == false)
        #expect(worker.starts == 0, "the screen is gone: the session must not start")
        #expect(!worker.running)
        #expect(camera.state == .closed)
    }

    @Test("a close while the session is starting ends with the camera off, though its stop came first")
    func closeDuringTheStart() async throws {
        let worker = FakeWorker(startGated: true)
        let camera = worker.lifecycle()
        let opening = Task { await camera.open() }
        try await waitUntil { worker.startGate.arrivals == 1 }

        camera.close() // this stop lands BEFORE the start below finishes
        worker.startGate.release()

        #expect(await opening.value == false)
        #expect(worker.starts == 1)
        #expect(!worker.running, "the overtaken start must be stopped again")
        #expect(camera.state == .closed)
    }

    @Test("a close then an open again opens: the new open does not join the overtaken one")
    func closeThenReopen() async throws {
        let worker = FakeWorker(accessGated: true)
        let camera = worker.lifecycle()
        let first = Task { await camera.open() }
        try await waitUntil { worker.accessGate.arrivals == 1 }
        camera.close()

        let second = Task { await camera.open() }
        try await waitUntil { worker.accessGate.arrivals == 2 }
        worker.accessGate.release()

        #expect(await first.value == false)
        #expect(await second.value)
        #expect(camera.state == .open)
        #expect(worker.running)
        #expect(worker.starts == 1, "only the open that still stands starts the session")
    }

    @Test("an overtaken start leaves a newer open's camera alone")
    func theOvertakenStartDoesNotStopTheNewOpen() async throws {
        let worker = FakeWorker(startGated: true)
        let camera = worker.lifecycle()
        let first = Task { await camera.open() }
        try await waitUntil { worker.startGate.arrivals == 1 }
        camera.close()
        let second = Task { await camera.open() }
        try await waitUntil { worker.startGate.arrivals == 2 }
        worker.startGate.release()

        #expect(await first.value == false)
        #expect(await second.value)
        #expect(camera.state == .open)
        #expect(worker.running)
    }

    @Test("two opens at once share one start")
    func concurrentOpensShareOneStart() async throws {
        let worker = FakeWorker(accessGated: true)
        let camera = worker.lifecycle()
        let first = Task { await camera.open() }
        let second = Task { await camera.open() }
        try await waitUntil { worker.accessGate.arrivals == 1 }
        await Task.yield()
        worker.accessGate.release()

        #expect(await first.value)
        #expect(await second.value)
        #expect(worker.accessGate.arrivals == 1)
        #expect(worker.starts == 1)
    }

    @Test("an open on an open camera is a no-op")
    func openTwice() async {
        let worker = FakeWorker()
        let camera = worker.lifecycle()
        #expect(await camera.open())
        #expect(await camera.open())
        #expect(worker.starts == 1)
    }

    @Test(
        "a refused camera says which refusal, and never starts",
        arguments: [
            (LookCameraLifecycle.Access.denied, LookCameraLifecycle.State.denied),
            (.restricted, .restricted),
        ]
    )
    func refused(access: LookCameraLifecycle.Access, state: LookCameraLifecycle.State) async {
        let worker = FakeWorker()
        worker.set(access: access)
        let camera = worker.lifecycle()
        #expect(await camera.open() == false)
        #expect(camera.state == state)
        #expect(!camera.isOn)
        #expect(worker.starts == 0)
        camera.close()
        #expect(camera.state == state, "a close does not wipe the reason the camera is off")
    }

    @Test("no camera, or a session that will not run, is unavailable")
    func unavailable() async {
        let none = FakeWorker()
        let without = none.lifecycle(hasCamera: false)
        #expect(await without.open() == false)
        #expect(without.state == .unavailable)
        #expect(none.accessGate.arrivals == 0, "no camera: permission is never asked")

        let broken = FakeWorker()
        broken.setStartSucceeds(false)
        let camera = broken.lifecycle()
        #expect(await camera.open() == false)
        #expect(camera.state == .unavailable)
        #expect(!broken.running)
    }

    @Test("a frame older than a second is not what the camera sees now")
    func staleFramesAreRefused() {
        #expect(LookFrame.fresh(age: .milliseconds(40)))
        #expect(LookFrame.fresh(age: .seconds(1)))
        #expect(!LookFrame.fresh(age: .milliseconds(1001)))
        #expect(!LookFrame.fresh(age: .seconds(30)))
    }
}
