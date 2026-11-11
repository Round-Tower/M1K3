//
//  PersonaWarmTests.swift
//  M1K3InferenceTests
//
//  The persona-prefix warm after a brain load was fire-and-forget: three launch paths each started one, nothing
//  cancelled them, and after Kev swapped Big → Lil (2026-10-20) Big kept prefilling two more 12B palettes for two
//  minutes while Lil loaded and his first turn waited. These pin the ledger (one warm per provider; a new provider
//  replaces the old) and the palette run (stops between palettes once told to).
//
//  Signed: Kev + claude-opus-5-5, 2026-10-20, Confidence 0.85. Prior: none (new file).

import Foundation
@testable import M1K3Inference
import Testing

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Int] = []
    func record(_ item: Int) {
        lock.withLock { items.append(item) }
    }

    var recorded: [Int] {
        lock.withLock { items }
    }
}

struct PersonaWarmLedgerTests {
    @Test("the first request for a provider starts a warm")
    func firstRequestStarts() {
        var ledger = PersonaWarmLedger<Int>()
        #expect(ledger.request(for: 1) == .start)
    }

    @Test("a second request for the same provider joins the running warm")
    func sameProviderIsDeduped() {
        var ledger = PersonaWarmLedger<Int>()
        _ = ledger.request(for: 1)
        #expect(ledger.request(for: 1) == .alreadyWarming)
    }

    @Test("a request for a different provider replaces the running warm")
    func newProviderReplaces() {
        var ledger = PersonaWarmLedger<Int>()
        _ = ledger.request(for: 1)
        #expect(ledger.request(for: 2) == .replace)
        #expect(ledger.request(for: 2) == .alreadyWarming)
    }

    @Test("a finished warm frees the slot, but only its own")
    func finishClearsOnlyItsOwn() {
        var ledger = PersonaWarmLedger<Int>()
        _ = ledger.request(for: 1)
        _ = ledger.request(for: 2) // 1 was replaced; its late finish must not clear 2
        ledger.finished(1)
        #expect(ledger.request(for: 2) == .alreadyWarming)
        ledger.finished(2)
        #expect(ledger.request(for: 2) == .start)
    }

    @Test("cancel empties the ledger")
    func cancelEmpties() {
        var ledger = PersonaWarmLedger<Int>()
        _ = ledger.request(for: 1)
        ledger.cancel()
        #expect(ledger.request(for: 1) == .start)
    }
}

struct PersonaWarmRunTests {
    @Test("every palette warms, in order, while nothing says stop")
    func runsAllInOrder() async {
        let recorder = Recorder()
        let ran = await PersonaWarmRun.run([0, 8, 15], shouldContinue: { true }, warm: { recorder.record($0) })
        #expect(ran == 3)
        #expect(recorder.recorded == [0, 8, 15])
    }

    @Test("a stop after the first palette skips the rest (the swap cancels the outgoing brain's warm)")
    func stopsBetweenPalettes() async {
        let recorder = Recorder()
        let ran = await PersonaWarmRun.run(
            [0, 8, 15], shouldContinue: { recorder.recorded.isEmpty }, warm: { recorder.record($0) }
        )
        #expect(ran == 1)
        #expect(recorder.recorded == [0])
    }

    @Test("a cancelled task warms nothing")
    func cancelledTaskWarmsNothing() async {
        let recorder = Recorder()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await PersonaWarmRun.run(
                [0, 8, 15], shouldContinue: { !Task.isCancelled }, warm: { recorder.record($0) }
            )
        }
        #expect(await task.value == 0)
        #expect(recorder.recorded.isEmpty)
    }
}

/// A busy flag a test flips, and the pauses the wait took.
private final class Busy: @unchecked Sendable {
    private let lock = NSLock()
    private var busyFor = 0
    private var pauses = 0
    init(polls: Int) {
        busyFor = polls
    }

    /// Busy for the first `polls` reads, then quiet.
    func read() -> Bool {
        lock.withLock {
            guard busyFor > 0 else { return false }
            busyFor -= 1
            return true
        }
    }

    func paused() {
        lock.withLock { pauses += 1 }
    }

    var pauseCount: Int {
        lock.withLock { pauses }
    }
}

/// #621: a turn that arrived while the launch warm was still building waited for it and then decoded beside
/// the next build (Big, 2026-11-11: 19 s to a first word, then 5 tok/s instead of 25). The warm now waits for
/// quiet before each palette.
struct PersonaWarmYieldTests {
    @Test("with nobody being answered the wait returns at once")
    func quietReturnsAtOnce() async {
        let busy = Busy(polls: 0)
        let waited = await PersonaWarmYield.untilQuiet(busy: { busy.read() }, pause: { _ in busy.paused() })
        #expect(waited == .quiet)
        #expect(busy.pauseCount == 0)
    }

    @Test("while someone is being answered it pauses, and goes on once they are done")
    func waitsOutATurn() async {
        let busy = Busy(polls: 3)
        let waited = await PersonaWarmYield.untilQuiet(busy: { busy.read() }, pause: { _ in busy.paused() })
        #expect(waited == .quiet)
        #expect(busy.pauseCount == 3)
    }

    @Test("it does not wait forever: past the limit the warm goes on, so a busy caller cannot starve it")
    func givesUpAtTheLimit() async {
        let busy = Busy(polls: .max)
        let waited = await PersonaWarmYield.untilQuiet(
            busy: { busy.read() }, limit: .seconds(10), step: .seconds(1), pause: { _ in busy.paused() }
        )
        #expect(waited == .limitReached)
        #expect(busy.pauseCount == 10)
    }

    @Test("a cancel during the wait ends it: the swap's cancel is not held up by a long answer")
    func cancelEndsTheWait() async {
        let busy = Busy(polls: .max)
        let waited = await PersonaWarmYield.untilQuiet(
            busy: { busy.read() }, pause: { _ in busy.paused(); throw CancellationError() }
        )
        #expect(waited == .cancelled)
        #expect(busy.pauseCount == 1)
    }

    @Test("the run waits before each palette, and a palette never starts while someone is being answered")
    func runYieldsBeforeEachPalette() async {
        let recorder = Recorder()
        let order = Recorder()
        let ran = await PersonaWarmRun.run(
            [0, 8, 15],
            beforeEach: { order.record(-1); return true },
            shouldContinue: { true },
            warm: { order.record($0); recorder.record($0) }
        )
        #expect(ran == 3)
        #expect(order.recorded == [-1, 0, -1, 8, -1, 15])
    }

    @Test("a stop that lands during the wait skips the palette it was waiting for")
    func stopDuringTheWait() async {
        let recorder = Recorder()
        let ran = await PersonaWarmRun.run(
            [0, 8, 15],
            beforeEach: { if recorder.recorded.count == 1 { recorder.record(-1) }; return true },
            shouldContinue: { !recorder.recorded.contains(-1) },
            warm: { recorder.record($0) }
        )
        #expect(ran == 1)
        #expect(recorder.recorded == [0, -1])
    }

    @Test("a wait that gave up ends the run: no palette is built beside the answer it waited for")
    func givingUpEndsTheRun() async {
        let recorder = Recorder()
        let ran = await PersonaWarmRun.run(
            [0, 8, 15],
            beforeEach: { recorder.recorded.isEmpty },
            shouldContinue: { true },
            warm: { recorder.record($0) }
        )
        #expect(ran == 1)
        #expect(recorder.recorded == [0])
        #expect(PersonaWarmYield.Outcome.quiet.goesOn)
        #expect(!PersonaWarmYield.Outcome.limitReached.goesOn)
        #expect(!PersonaWarmYield.Outcome.cancelled.goesOn)
    }
}
