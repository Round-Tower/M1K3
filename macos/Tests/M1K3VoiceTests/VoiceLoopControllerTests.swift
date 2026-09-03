import Foundation
import M1K3Voice
import Testing

/// Behavior tests for the voice-loop driver with closure fakes: the full
/// hands-free beat (listen → turn → speak → re-listen), the silence endpoint,
/// barge-in, exit-mid-turn, and error paths. Time-based bits use tiny
/// thresholds so the tests run in milliseconds.
@MainActor
struct VoiceLoopControllerTests {
    /// Scriptable dependency recorder.
    @MainActor
    final class Harness {
        var listenStarts = 0
        var stopListens = 0
        var turns: [String] = []
        var spoken: [String] = []
        var stopSpeaks = 0
        var continuation: AsyncStream<TranscriptSegment>.Continuation?
        var turnResult: Result<String, VoiceTurnFailure> = .success("the answer")
        /// When set, runTurn suspends until the gate task completes.
        var turnGate: CheckedContinuation<Void, Never>?
        var holdTurn = false
        var listenThrows = false

        func dependencies() -> VoiceLoopController.Dependencies {
            VoiceLoopController.Dependencies(
                startListening: {
                    self.listenStarts += 1
                    if self.listenThrows { throw VoiceTurnFailure(message: "no mic") }
                    return AsyncStream { self.continuation = $0 }
                },
                stopListening: {
                    self.stopListens += 1
                    self.continuation?.finish()
                    self.continuation = nil
                },
                runTurn: { question in
                    self.turns.append(question)
                    if self.holdTurn {
                        await withCheckedContinuation { self.turnGate = $0 }
                    }
                    return self.turnResult
                },
                speak: { self.spoken.append($0) },
                stopSpeaking: { self.stopSpeaks += 1 }
            )
        }
    }

    private func makeController(
        _ harness: Harness,
        silence: Duration = .milliseconds(50),
        holdSilence: Duration = .seconds(3.0)
    ) -> VoiceLoopController {
        VoiceLoopController(
            dependencies: harness.dependencies(),
            silence: silence,
            holdSilence: holdSilence,
            echoGrace: .zero,
            endpointTick: .milliseconds(10)
        )
    }

    /// Poll until `condition` holds (5ms steps, ~1s budget).
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0 ..< 200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - The hands-free beat

    @Test("listen → finality → turn → speak → speech end → re-listen")
    func fullBeat() async {
        let harness = Harness()
        // Long silence so this test exercises the FINALITY path in isolation — the
        // silence endpoint must not race-fire on the "what's" partial before the
        // final "what's the time" segment arrives (the CI-load flake). holdSilence
        // is raised in lockstep to satisfy SilenceEndpointer's holdSilence ≥ silence
        // precondition.
        let controller = makeController(harness, silence: .seconds(30), holdSilence: .seconds(30))

        controller.begin()
        await waitUntil { harness.continuation != nil }
        #expect(harness.listenStarts == 1)

        harness.continuation?.yield(TranscriptSegment(text: "what's", isFinal: false))
        await waitUntil { controller.state == .listening(partial: "what's") }
        harness.continuation?.yield(TranscriptSegment(text: "what's the time", isFinal: true))
        harness.continuation?.finish()

        await waitUntil { !harness.spoken.isEmpty }
        #expect(harness.turns == ["what's the time"])
        #expect(harness.spoken == ["the answer"])
        #expect(controller.state == .speaking(answer: "the answer"))

        controller.speechDidEnd()
        await waitUntil { harness.listenStarts == 2 }
        #expect(harness.listenStarts == 2)
        #expect(controller.state == .listening(partial: ""))
    }

    // MARK: - Latency instrument

    @Test("a spoken turn reports its own latency once audio starts")
    func turnLatencyIsRecorded() async throws {
        let harness = Harness()
        let controller = makeController(harness, silence: .seconds(30), holdSilence: .seconds(30))

        controller.begin()
        await waitUntil { harness.continuation != nil }
        harness.continuation?.yield(TranscriptSegment(text: "how fast are you", isFinal: true))
        harness.continuation?.finish()
        await waitUntil { !harness.spoken.isEmpty }
        // Generation has completed (whole-answer path) but nothing has been heard
        // yet — reporting now would call every such turn silent.
        #expect(controller.lastTurnLatency == nil)

        controller.speechDidStart()
        let summary = try #require(controller.lastTurnLatency)
        #expect(summary.hasPrefix("voice turn: "))
        #expect(summary.contains("first audio"))
        #expect(summary.contains("1 sentence"))
    }

    @Test("a turn abandoned by barge-in still reports — the impatient turns are the ones that matter")
    func bargeInStillReportsLatency() async throws {
        let harness = Harness()
        harness.holdTurn = true
        let controller = makeController(harness, silence: .seconds(30), holdSilence: .seconds(30))

        controller.begin()
        await waitUntil { harness.continuation != nil }
        harness.continuation?.yield(TranscriptSegment(text: "take your time", isFinal: true))
        harness.continuation?.finish()
        await waitUntil { !harness.turns.isEmpty }

        controller.interrupt()
        let summary = try #require(controller.lastTurnLatency)
        #expect(summary.contains("no audio"))
        #expect(summary.contains("0 sentences"))

        harness.turnGate?.resume()
    }

    @Test("a stale speech-started callback cannot settle a turn that hasn't spoken")
    func staleSpeechStartCannotSettleTheTurn() async throws {
        // The audio layer's started-callback is genuinely asynchronous — a
        // barged-in turn's TTS tail can fire it late, landing the mark in the
        // NEXT turn's timeline. "First wins" would then keep the bogus instant,
        // and the streaming path's completion flush would settle and log the
        // turn as spoken before anything was heard.
        let harness = Harness()
        var deps = harness.dependencies()
        deps.runTurnStreaming = { _, onChunk in
            await withCheckedContinuation { harness.turnGate = $0 }
            onChunk("The answer.")
            return .success(())
        }
        let controller = VoiceLoopController(
            dependencies: deps, silence: .seconds(30),
            holdSilence: .seconds(30), echoGrace: .zero, endpointTick: .milliseconds(10)
        )

        controller.begin()
        await waitUntil { harness.continuation != nil }
        harness.continuation?.yield(TranscriptSegment(text: "how fast are you", isFinal: true))
        harness.continuation?.finish()
        await waitUntil { harness.turnGate != nil }

        // The stale callback arrives mid-generation — no sentence exists yet,
        // so this audio provably belongs to a previous turn.
        controller.speechDidStart()

        harness.turnGate?.resume()
        await waitUntil { !harness.spoken.isEmpty }
        try? await Task.sleep(for: .milliseconds(30)) // let .answerCompleted land

        // Generation finished; nothing has actually played. The stale mark must
        // not have settled (and flushed) the turn.
        #expect(controller.lastTurnLatency == nil)

        // The REAL audio start settles it, and owns the number.
        controller.speechDidStart()
        let summary = try #require(controller.lastTurnLatency)
        #expect(summary.contains("first audio"))
    }

    @Test("a stalled partial endpoints by silence — no finality needed")
    func silenceEndpoint() async {
        let harness = Harness()
        let controller = makeController(harness)

        controller.begin()
        await waitUntil { harness.continuation != nil }
        harness.continuation?.yield(TranscriptSegment(text: "hello there", isFinal: false))
        // No more segments, no finality: the endpointer must close the listen.
        await waitUntil { !harness.turns.isEmpty }
        #expect(harness.turns == ["hello there"])
        #expect(harness.stopListens >= 1)
    }

    // MARK: - Empty listens

    @Test("two empty listens park the loop in idle")
    func emptyListensPark() async {
        let harness = Harness()
        let controller = makeController(harness)

        controller.begin()
        await waitUntil { harness.continuation != nil }
        harness.continuation?.finish() // nothing said

        await waitUntil { harness.listenStarts == 2 }
        await waitUntil { harness.continuation != nil }
        harness.continuation?.finish() // nothing again

        await waitUntil { controller.state == .idle }
        #expect(controller.state == .idle)
        #expect(harness.listenStarts == 2)
        #expect(harness.turns.isEmpty)
    }

    // MARK: - Barge-in

    @Test("interrupt while speaking stops speech and re-listens; the stale end is ignored")
    func bargeIn() async {
        let harness = Harness()
        let controller = makeController(harness)

        controller.begin()
        await waitUntil { harness.continuation != nil }
        harness.continuation?.yield(TranscriptSegment(text: "hi", isFinal: true))
        harness.continuation?.finish()
        await waitUntil { !harness.spoken.isEmpty }

        controller.interrupt()
        await waitUntil { harness.listenStarts == 2 }
        #expect(harness.stopSpeaks == 1)
        #expect(controller.state == .listening(partial: ""))

        // stop() makes the provider fire onSpeakingEnded → stale speechFinished.
        controller.speechDidEnd()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(harness.listenStarts == 2) // no third listen
    }

    // MARK: - Exit

    @Test("exit mid-turn: the turn completes but is never spoken")
    func exitMidTurn() async {
        let harness = Harness()
        harness.holdTurn = true
        let controller = makeController(harness)

        controller.begin()
        await waitUntil { harness.continuation != nil }
        harness.continuation?.yield(TranscriptSegment(text: "deep question", isFinal: true))
        harness.continuation?.finish()
        await waitUntil { !harness.turns.isEmpty }

        controller.exit()
        #expect(controller.state == .ended)

        // The held turn now completes — into the void.
        harness.turnGate?.resume()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(harness.spoken.isEmpty)
        #expect(controller.state == .ended)
    }

    // MARK: - Errors

    @Test("a failed turn parks in idle and surfaces the error")
    func turnFailure() async {
        let harness = Harness()
        harness.turnResult = .failure(VoiceTurnFailure(message: "brain offline"))
        let controller = makeController(harness)

        controller.begin()
        await waitUntil { harness.continuation != nil }
        harness.continuation?.yield(TranscriptSegment(text: "hello", isFinal: true))
        harness.continuation?.finish()

        await waitUntil { controller.state == .idle }
        #expect(controller.lastError == "brain offline")
        #expect(harness.spoken.isEmpty)
    }

    @Test("a mic that fails to start parks in idle with the error")
    func micFailure() async {
        let harness = Harness()
        harness.listenThrows = true
        let controller = makeController(harness)

        controller.begin()
        await waitUntil { controller.state == .idle && controller.lastError != nil }
        #expect(controller.state == .idle)
        #expect(controller.lastError != nil)
    }

    @Test("begin clears the previous error")
    func beginClearsError() async {
        let harness = Harness()
        harness.listenThrows = true
        let controller = makeController(harness)
        controller.begin()
        await waitUntil { controller.lastError != nil }

        harness.listenThrows = false
        controller.begin()
        await waitUntil { harness.listenStarts == 2 }
        #expect(controller.lastError == nil)
    }

    // MARK: - Recogniser failure + patience (2026-09-03)

    @Test("listenFailed parks with the reason instead of re-arming into the same wall")
    func listenFailedParksWithReason() async {
        let harness = Harness()
        let controller = makeController(harness)
        controller.begin()
        await waitUntil { harness.listenStarts == 1 }

        // The adapter reports BEFORE it finishes the stream — the pending
        // listen must be cancelled, not counted as an empty listen.
        controller.listenFailed("Failed to initialize recognizer")
        await waitUntil { controller.state == .idle }
        #expect(controller.lastError == "Failed to initialize recognizer")
        #expect(harness.stopListens == 1)

        // Give a stale re-arm every chance to show up: it must not.
        try? await Task.sleep(for: .milliseconds(30))
        #expect(harness.listenStarts == 1)
    }

    @Test("pause while speaking stops speech and parks; the stale end never re-listens")
    func pauseWhileSpeakingParks() async {
        let harness = Harness()
        let controller = makeController(harness)

        controller.begin()
        await waitUntil { harness.continuation != nil }
        harness.continuation?.yield(TranscriptSegment(text: "hi", isFinal: true))
        harness.continuation?.finish()
        await waitUntil { !harness.spoken.isEmpty }

        controller.pause()
        await waitUntil { harness.stopSpeaks == 1 }
        #expect(controller.state == .idle)

        // stop() makes the provider fire onSpeakingEnded → a stale speechFinished
        // that must not wake the parked loop.
        controller.speechDidEnd()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(harness.listenStarts == 1)
        #expect(controller.state == .idle)
    }

    @Test("the cadence's empty-listen budget reaches the machine")
    func cadenceEmptyListenBudgetReachesTheMachine() async {
        let harness = Harness()
        let cadence = EndpointCadence(
            silence: .milliseconds(50),
            hold: .seconds(3),
            maxWait: .seconds(20),
            cadenceMargin: .zero,
            cadenceCeiling: .seconds(3),
            emptyListensBeforeParking: 3
        )
        let controller = VoiceLoopController(
            dependencies: harness.dependencies(),
            cadence: cadence,
            echoGrace: .zero,
            endpointTick: .milliseconds(10)
        )
        controller.begin()

        // Two quiet listens (the recogniser ends each stream with no segments)
        // re-arm under a budget of 3 — under the default they'd have parked.
        for expected in 1 ... 2 {
            await waitUntil { harness.listenStarts == expected && harness.continuation != nil }
            harness.continuation?.finish()
            await waitUntil { harness.listenStarts == expected + 1 }
        }
        #expect(controller.state == .listening(partial: ""))

        await waitUntil { harness.continuation != nil }
        harness.continuation?.finish()
        await waitUntil { controller.state == .idle }
        #expect(harness.listenStarts == 3)
    }

    // MARK: - Sentence-streamed turns (2026-07-25)

    /// A streaming harness: the turn emits scripted chunks, then completes.
    /// speak() records and returns immediately; speechDidEnd() is fired
    /// manually per utterance, as the app's onSpeakingEnded wiring does.
    @Test("streamed chunks speak in order and re-listen waits for the drain")
    func streamedChunksSpeakInOrder() async {
        let harness = Harness()
        var deps = harness.dependencies()
        deps.runTurnStreaming = { _, onChunk in
            onChunk("One.")
            onChunk("Two.")
            return .success(())
        }
        let controller = VoiceLoopController(
            dependencies: deps, silence: .milliseconds(50),
            holdSilence: .seconds(3), echoGrace: .zero, endpointTick: .milliseconds(10)
        )
        controller.begin()
        await waitUntil { harness.continuation != nil }
        harness.continuation?.yield(TranscriptSegment(text: "question", isFinal: true))
        harness.continuation?.finish()

        // Both chunks reach speak, in order, while the loop stays speaking.
        await waitUntil { harness.spoken.count == 2 }
        #expect(harness.spoken == ["One.", "Two."])
        if case .speaking = controller.state {} else {
            Issue.record("expected .speaking, got \(controller.state)")
        }

        // First utterance ends — still speaking (one chunk unspoken).
        controller.speechDidEnd()
        try? await Task.sleep(for: .milliseconds(20))
        if case .speaking = controller.state {} else {
            Issue.record("expected .speaking after first chunk end, got \(controller.state)")
        }
        // Second ends — generation already completed → re-listen.
        controller.speechDidEnd()
        await waitUntil { harness.listenStarts == 2 }
        #expect(harness.listenStarts == 2)
    }

    @Test("a stale turn's late completion cannot park a fresh turn (generation guard)")
    func staleTurnCompletionDropped() async {
        // Turn A streams a chunk, then the user barges in and asks turn B.
        // Turn A's runTurnStreaming is still in flight; its late .answerCompleted
        // must NOT park turn B (which is awaiting its own answer).
        let harness = Harness()
        var deps = harness.dependencies()
        let gateA = TurnGate()
        var turnIndex = 0
        deps.runTurnStreaming = { _, onChunk in
            turnIndex += 1
            if turnIndex == 1 {
                onChunk("Turn A first sentence.")
                await gateA.wait() // hold turn A open until the test releases it
                return .success(()) // late completion — must be ignored
            }
            onChunk("Turn B answer.")
            return .success(())
        }
        let controller = VoiceLoopController(
            dependencies: deps, silence: .milliseconds(50),
            holdSilence: .seconds(3), echoGrace: .zero, endpointTick: .milliseconds(10)
        )
        controller.begin()
        await waitUntil { harness.continuation != nil }
        harness.continuation?.yield(TranscriptSegment(text: "question A", isFinal: true))
        harness.continuation?.finish()
        await waitUntil { harness.spoken == ["Turn A first sentence."] }

        // Barge in, then ask turn B.
        controller.interrupt()
        await waitUntil { harness.continuation != nil }
        harness.continuation?.yield(TranscriptSegment(text: "question B", isFinal: true))
        harness.continuation?.finish()
        await waitUntil { harness.spoken.contains("Turn B answer.") }

        // Release turn A's late completion — it must be a no-op for turn B.
        await gateA.open()
        try? await Task.sleep(for: .milliseconds(30))
        if case .speaking = controller.state {} else {
            Issue.record("turn B should still be speaking, got \(controller.state)")
        }
    }

    @Test("a streamed turn that fails before any chunk parks idle with the error")
    func streamedFailureParks() async {
        let harness = Harness()
        var deps = harness.dependencies()
        deps.runTurnStreaming = { _, _ in
            .failure(VoiceTurnFailure(message: "brain fell over"))
        }
        let controller = VoiceLoopController(
            dependencies: deps, silence: .milliseconds(50),
            holdSilence: .seconds(3), echoGrace: .zero, endpointTick: .milliseconds(10)
        )
        controller.begin()
        await waitUntil { harness.continuation != nil }
        harness.continuation?.yield(TranscriptSegment(text: "question", isFinal: true))
        harness.continuation?.finish()

        await waitUntil { controller.lastError != nil }
        #expect(controller.lastError == "brain fell over")
        await waitUntil { controller.state == .idle }
        #expect(harness.spoken.isEmpty)
    }
}

/// A one-shot gate a streaming turn awaits, so a test can hold a turn's
/// generation open across a barge-in and release its late completion.
private actor TurnGate {
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
