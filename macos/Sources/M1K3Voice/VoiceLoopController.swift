//
//  VoiceLoopController.swift
//  M1K3Voice
//
//  The driver for voice-first mode: executes VoiceLoopMachine commands against
//  the real seams (mic stream, chat turn, TTS) via injected closures, so the
//  loop logic stays testable with fakes and this class owns only task
//  lifetimes. Main-actor: every event funnels through dispatch(), state is
//  observable for the UI.
//
//  Task rules (pinned by tests):
//  • The listen task consumes the transcript stream; a ~tick poll closes the
//    listen by SILENCE (SilenceEndpointer) because recognizer finality can lag
//    seconds behind the user being done.
//  • The turn task is UNSTRUCTURED and held — exit() does not cancel it. The
//    answer still lands in the chat transcript; the machine (in .ended) just
//    never speaks it.
//  • speak is enqueue-style: completion arrives via speechDidEnd(), wired from
//    the speech provider's onSpeakingEnded by the app layer.
//
//  Signed: Kev + claude-fable-5, 2026-06-11, Confidence 0.85 (behavior
//  test-pinned with fakes; real-seam wiring is the app layer's). Prior: Unknown.
//

import Foundation
import Observation
import os

/// A user-facing turn failure (the message is shown, not logged-and-lost).
public struct VoiceTurnFailure: Error, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

@MainActor
@Observable
public final class VoiceLoopController {
    private static let log = Logger(subsystem: "app.m1k3", category: "stt")
    /// The loop's real-world effects, injected as closures so tests fake them
    /// and the app layer adapts its existing seams without this type importing
    /// chat/avatar machinery.
    public struct Dependencies {
        public var startListening: @MainActor () throws -> AsyncStream<TranscriptSegment>
        public var stopListening: @MainActor () -> Void
        public var runTurn: @MainActor (String) async -> Result<String, VoiceTurnFailure>
        public var speak: @MainActor (String) async -> Void
        public var stopSpeaking: @MainActor () async -> Void
        /// Sentence-streaming turn (2026-07-25): emits speakable chunks via the
        /// callback WHILE the model generates and returns when generation
        /// finishes — first audio at the first sentence, not after the whole
        /// answer. nil falls back to the whole-answer `runTurn`.
        public var runTurnStreaming: (@MainActor (
            _ question: String,
            _ onChunk: @escaping @MainActor (String) -> Void
        ) async -> Result<Void, VoiceTurnFailure>)?

        public init(
            startListening: @escaping @MainActor () throws -> AsyncStream<TranscriptSegment>,
            stopListening: @escaping @MainActor () -> Void,
            runTurn: @escaping @MainActor (String) async -> Result<String, VoiceTurnFailure>,
            speak: @escaping @MainActor (String) async -> Void,
            stopSpeaking: @escaping @MainActor () async -> Void,
            runTurnStreaming: (@MainActor (
                _ question: String,
                _ onChunk: @escaping @MainActor (String) -> Void
            ) async -> Result<Void, VoiceTurnFailure>)? = nil
        ) {
            self.startListening = startListening
            self.stopListening = stopListening
            self.runTurn = runTurn
            self.speak = speak
            self.stopSpeaking = stopSpeaking
            self.runTurnStreaming = runTurnStreaming
        }
    }

    public private(set) var state: VoiceLoopState = .idle
    public private(set) var lastError: String?

    private var machine = VoiceLoopMachine()
    private let dependencies: Dependencies
    private let echoGrace: Duration
    private let endpointTick: Duration
    private let silence: Duration

    private var listenTask: Task<Void, Never>?
    private var endpointTask: Task<Void, Never>?
    /// Held, never cancelled by exit — see the header.
    private var turnTask: Task<Void, Never>?
    private var speakTask: Task<Void, Never>?
    /// Monotonic turn counter — a held-but-superseded turn's late answer events
    /// are dropped by matching against this (see `.runTurn`).
    private var turnGeneration = 0
    /// Chunks awaiting the serial speak drainer (sentence streaming).
    private var speechQueue: [String] = []
    private var accumulator = TranscriptAccumulator()
    private var endpointer: SilenceEndpointer

    public init(
        dependencies: Dependencies,
        silence: Duration = .seconds(1.6),
        holdSilence: Duration = .seconds(3.0),
        maxWait: Duration = .seconds(20),
        echoGrace: Duration = .milliseconds(350),
        endpointTick: Duration = .milliseconds(300)
    ) {
        self.dependencies = dependencies
        self.silence = silence
        self.echoGrace = echoGrace
        self.endpointTick = endpointTick
        endpointer = SilenceEndpointer(silence: silence, holdSilence: holdSilence, maxWait: maxWait)
    }

    // MARK: - User intents

    public func begin() {
        lastError = nil
        dispatch(.begin)
    }

    public func interrupt() {
        dispatch(.interrupt)
    }

    public func mute() {
        dispatch(.mute)
    }

    public func exit() {
        dispatch(.exit)
    }

    /// Wire from the speech provider's onSpeakingEnded.
    public func speechDidEnd() {
        dispatch(.speechFinished)
    }

    // MARK: - Reducer plumbing

    private func dispatch(_ event: VoiceLoopEvent) {
        let commands = machine.handle(event)
        state = machine.state
        for command in commands {
            execute(command)
        }
    }

    /// Dispatch an answer event ONLY if it belongs to the current turn — a
    /// superseded turn's held task (barge-in + new question) is silenced here.
    private func dispatchAnswerEvent(_ event: VoiceLoopEvent, generation: Int) {
        guard generation == turnGeneration else { return }
        dispatch(event)
    }

    private func recordTurnFailure(_ message: String, generation: Int) {
        guard generation == turnGeneration else { return }
        lastError = message
        Self.log.error("voice turn failed: \(message, privacy: .public)")
        dispatch(.answerFailed(message))
    }

    private func execute(_ command: VoiceLoopCommand) {
        switch command {
        case let .startListening(afterEchoGrace):
            startListen(graced: afterEchoGrace)

        case .stopListening:
            listenTask?.cancel()
            listenTask = nil
            endpointTask?.cancel()
            endpointTask = nil
            dependencies.stopListening()

        case let .runTurn(question):
            // Turn generation: a streaming turn's task stays in flight for the
            // WHOLE speaking phase (it's still generating while chunks play), so
            // a barge-in + new question leaves the PREVIOUS turn's task alive.
            // Its late answerChunk/Completed/Failed must not corrupt the new
            // turn (park it, speak a stale chunk). Each turn captures its
            // generation; dispatchAnswerEvent drops events from a superseded
            // turn (the turnTask is held-not-cancelled by design, so we can't
            // rely on cancellation to silence it). 2026-07-25 review finding.
            turnGeneration &+= 1
            let generation = turnGeneration
            turnTask = Task { [weak self] in
                guard let dependencies = self?.dependencies else { return }
                if let streaming = dependencies.runTurnStreaming {
                    switch await streaming(question, { [weak self] chunk in
                        self?.dispatchAnswerEvent(.answerChunk(chunk), generation: generation)
                    }) {
                    case .success:
                        self?.dispatchAnswerEvent(.answerCompleted, generation: generation)
                    case let .failure(failure):
                        self?.recordTurnFailure(failure.message, generation: generation)
                    }
                    return
                }
                switch await dependencies.runTurn(question) {
                case let .success(answer):
                    self?.dispatchAnswerEvent(.answerReady(answer), generation: generation)
                case let .failure(failure):
                    self?.recordTurnFailure(failure.message, generation: generation)
                }
            }

        case let .speak(answer):
            // Serial queue, one utterance in flight: chunks must play in order
            // and the provider's per-utterance onSpeakingEnded (→ speechDidEnd
            // → the machine's chunk countdown) must fire once per queued item.
            speechQueue.append(answer)
            drainSpeechQueueIfIdle()

        case .stopSpeaking:
            // The cancel is advisory (speak providers are enqueue-style and
            // don't observe it) — the audio actually stops via the
            // stopSpeaking dependency below. Pending chunks are abandoned:
            // the machine already left .speaking, so their countdown is moot.
            speechQueue.removeAll()
            speakTask?.cancel()
            speakTask = nil
            Task { [weak self] in await self?.dependencies.stopSpeaking() }
        }
    }

    /// One drainer at a time; it exits when the queue empties and is re-armed
    /// by the next enqueue.
    private func drainSpeechQueueIfIdle() {
        guard speakTask == nil else { return }
        speakTask = Task { [weak self] in
            while !Task.isCancelled, let next = self?.nextSpeechChunk() {
                await self?.dependencies.speak(next)
            }
            // Only clear the slot if we finished NATURALLY. A cancelled drainer
            // (stopSpeaking) must not nil `speakTask` — stopSpeaking already
            // did, and a fresh drainer may now own the slot; clobbering it
            // orphans that live task and lets a THIRD drainer spawn, so two run
            // concurrently and utterances overlap. 2026-07-25 review finding.
            if !Task.isCancelled { self?.speakTask = nil }
        }
    }

    private func nextSpeechChunk() -> String? {
        speechQueue.isEmpty ? nil : speechQueue.removeFirst()
    }

    // MARK: - Listening internals

    private func startListen(graced: Bool) {
        accumulator = TranscriptAccumulator()
        endpointer.reset()
        let grace = graced ? echoGrace : .zero
        listenTask = Task { [weak self] in
            if grace > .zero { try? await Task.sleep(for: grace) }
            guard let self, !Task.isCancelled else { return }
            let stream: AsyncStream<TranscriptSegment>
            do {
                stream = try dependencies.startListening()
            } catch {
                lastError = error.localizedDescription
                Self.log.error("voice mic unavailable, parking: \(error.localizedDescription, privacy: .public)")
                dispatch(.mute) // park: mic unavailable
                return
            }
            startEndpointTick()
            for await segment in stream {
                guard !Task.isCancelled else { return }
                accumulator.ingest(segment)
                endpointer.ingest(partial: accumulator.text, at: ContinuousClock.now)
                dispatch(.partial(accumulator.text))
            }
            // Stream ended (recognizer finality). If a silence endpoint already
            // moved the machine on, this event is stale and dropped there.
            guard !Task.isCancelled else { return }
            dispatch(.endpointed(sanitizedUtterance()))
        }
    }

    /// The final transcript, hygiene-cleaned for the model (repetition / silence
    /// hallucinations / whitespace). An all-noise utterance becomes "" so the
    /// machine's empty-listen guard parks/re-listens instead of running a ghost turn.
    private func sanitizedUtterance() -> String {
        TranscriptSanitizer.clean(accumulator.text, confidence: accumulator.confidence)
    }

    private func startEndpointTick() {
        endpointTask?.cancel()
        endpointTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.endpointTick ?? .milliseconds(300))
                guard let self, !Task.isCancelled else { return }
                if endpointer.shouldEndpoint(at: ContinuousClock.now) {
                    dispatch(.endpointed(sanitizedUtterance()))
                    return
                }
            }
        }
    }
}
