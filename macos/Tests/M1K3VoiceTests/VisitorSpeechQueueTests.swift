//
//  VisitorSpeechQueueTests.swift
//  M1K3VoiceTests
//
//  Pins the FIFO contract behind #283: a second MCP client's `speak` must
//  queue behind whichever utterance is already in flight instead of cutting
//  it. `speakNow`/`isSpeaking` are fakes here — the real closures (the app's
//  existing `speak(text, narrator:)` and `speech.isSpeaking()`) are app glue,
//  verify-by-launch with two live MCP clients.
//

@testable import M1K3Voice
import Testing

/// A one-shot gate a fake `speakNow` can hold open, mirroring VoiceLoopControllerTests'
/// TurnGate: lets a test hold "the utterance currently playing" open across
/// assertions and release it deterministically, with no wall-clock sleeps.
private actor SpeakGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

/// Thread-safe append-only log a fake `speakNow` records into, so a test can
/// assert ORDER without racing the actor under test.
private actor CallLog {
    private(set) var entries: [String] = []
    func record(_ entry: String) {
        entries.append(entry)
    }
}

private func request(_ text: String, narrator: Narrator = .visitor("agent")) -> VisitorSpeechQueue.SpeechRequest {
    VisitorSpeechQueue.SpeechRequest(text: text, emotion: nil, narrator: narrator)
}

struct VisitorSpeechQueueTests {
    @Test("an empty queue with nothing speaking plays immediately")
    func playsImmediatelyWhenIdle() async throws {
        let log = CallLog()
        let queue = VisitorSpeechQueue(
            speakNow: { req in await log.record("spoke:\(req.text)") },
            isSpeaking: { false }
        )
        try await queue.enqueue(request("hello"), wait: true)
        #expect(await log.entries == ["spoke:hello"])
        #expect(await queue.count == 0)
    }

    @Test("two concurrent enqueues play in order and the second starts only after the first's speakNow returns")
    func playsInFIFOOrder() async throws {
        let log = CallLog()
        let firstGate = SpeakGate()
        let queue = VisitorSpeechQueue(
            speakNow: { req in
                await log.record("start:\(req.text)")
                if req.text == "first" {
                    await firstGate.wait()
                }
                await log.record("end:\(req.text)")
            },
            isSpeaking: { false }
        )

        async let firstCall: Void = queue.enqueue(request("first"), wait: true)
        // Give the first call a beat to be admitted and start playing before
        // the second arrives — otherwise both could see an empty queue.
        try await Task.sleep(for: .milliseconds(20))
        async let secondCall: Void = queue.enqueue(request("second"), wait: true)
        try await Task.sleep(for: .milliseconds(20))
        // The second must be admitted (queued) but NOT started yet.
        #expect(await queue.count == 1)
        #expect(await log.entries == ["start:first"])

        await firstGate.open()
        _ = try await (firstCall, secondCall)

        #expect(await log.entries == ["start:first", "end:first", "start:second", "end:second"])
        #expect(await queue.count == 0)
    }

    @Test("clear() drops a pending request and its waiting caller sees Cancelled")
    func clearDropsPending() async throws {
        let log = CallLog()
        let holdFirst = SpeakGate()
        let queue = VisitorSpeechQueue(
            speakNow: { req in
                await log.record("start:\(req.text)")
                if req.text == "first" {
                    await holdFirst.wait()
                }
            },
            isSpeaking: { false }
        )

        // Plain Task handles, not `async let` — Swift Testing's `#expect(throws:)`
        // macro can't capture an `async let` variable inside its closure.
        let firstTask = Task { try await queue.enqueue(request("first"), wait: true) }
        try await Task.sleep(for: .milliseconds(20))

        let secondTask = Task { try await queue.enqueue(request("second"), wait: true) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await queue.count == 1)

        await queue.clear()
        #expect(await queue.count == 0)

        await #expect(throws: VisitorSpeechQueue.Cancelled.self) {
            try await secondTask.value
        }

        // The one already playing is unaffected by clear() — only stopped
        // separately, by the caller stopping playback itself.
        await holdFirst.open()
        try await firstTask.value
        #expect(await log.entries == ["start:first"])
    }

    @Test("a call beyond the cap refuses instead of growing the queue forever")
    func refusesBeyondCap() async throws {
        let entered = SpeakGate()
        let hold = SpeakGate()
        let queue = VisitorSpeechQueue(
            cap: 2,
            speakNow: { _ in
                await entered.open()
                await hold.wait()
            },
            isSpeaking: { false }
        )

        try await queue.enqueue(request("A"), wait: false)
        await entered.wait() // A is now actively playing (popped off the pending count)
        try await queue.enqueue(request("B"), wait: false) // queued = 1
        try await queue.enqueue(request("C"), wait: false) // queued = 2 == cap
        #expect(await queue.count == 2)

        await #expect(throws: VisitorSpeechQueue.Full.self) {
            try await queue.enqueue(request("D"), wait: false)
        }
        #expect(await queue.count == 2)

        await hold.open() // let A/B/C finish so no task is left hanging
    }

    @Test("something already speaking (not ours) makes an otherwise-empty queue wait")
    func waitsBehindExternalSpeech() async throws {
        let log = CallLog()
        let stillSpeaking = ExternalSpeakingFlag(true)
        let queue = VisitorSpeechQueue(
            speakNow: { req in await log.record("spoke:\(req.text)") },
            isSpeaking: { await stillSpeaking.value }
        )

        async let call: Void = queue.enqueue(request("hello"), wait: true)
        try await Task.sleep(for: .milliseconds(50))
        // The external utterance is still going — ours must not have played yet.
        #expect(await log.entries.isEmpty)

        await stillSpeaking.set(false)
        try await call
        #expect(await log.entries == ["spoke:hello"])
    }
}

/// A tiny actor-guarded flag standing in for `speech.isSpeaking()` reporting
/// on an utterance that isn't ours (e.g. the Speak App Intent, which never
/// routes through this queue).
private actor ExternalSpeakingFlag {
    private(set) var value: Bool
    init(_ value: Bool) {
        self.value = value
    }

    func set(_ newValue: Bool) {
        value = newValue
    }
}
