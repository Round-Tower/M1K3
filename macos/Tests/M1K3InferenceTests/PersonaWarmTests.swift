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
