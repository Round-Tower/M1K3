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
//  Review: Kev + claude-fable-5, 2026-09-03 — `listenFailed(_:)` parks with the
//  recogniser's own reason (a stream that opens and dies is not silence); the
//  machine's empty-listen budget now comes from the cadence.
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

    /// The last completed turn's latency line (the same text that goes to the
    /// unified log). Public so the numbers are assertable from the loop's own
    /// fakes rather than only observable by reading a log after the fact.
    public private(set) var lastTurnLatency: String?

    private var machine: VoiceLoopMachine
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
    /// This turn's latency envelope (see VoiceTurnTimeline). Reset per turn,
    /// flushed to the log the moment it settles.
    private var timeline = VoiceTurnTimeline()

    public init(
        dependencies: Dependencies,
        silence: Duration = .seconds(1.6),
        holdSilence: Duration = .seconds(3.0),
        maxWait: Duration = .seconds(20),
        echoGrace: Duration = .milliseconds(350),
        endpointTick: Duration = .milliseconds(300),
        cadenceMargin: Duration = EndpointCadence.conversational.cadenceMargin,
        cadenceCeiling: Duration = EndpointCadence.conversational.cadenceCeiling,
        politeSilence: Duration = EndpointCadence.conversational.polite,
        emptyListensBeforeParking: Int = 2
    ) {
        self.dependencies = dependencies
        self.silence = silence
        self.echoGrace = echoGrace
        self.endpointTick = endpointTick
        machine = VoiceLoopMachine(maxEmptyListens: emptyListensBeforeParking)
        endpointer = SilenceEndpointer(
            silence: silence,
            holdSilence: holdSilence,
            maxWait: maxWait,
            cadenceMargin: cadenceMargin,
            cadenceCeiling: cadenceCeiling,
            politeSilence: politeSilence
        )
    }

    /// The shell-facing init: one shared preset instead of five literals typed
    /// into each shell (which is how the Mac and iOS timings drifted apart).
    public convenience init(
        dependencies: Dependencies,
        cadence: EndpointCadence,
        echoGrace: Duration = .milliseconds(350),
        endpointTick: Duration = .milliseconds(300)
    ) {
        self.init(
            dependencies: dependencies,
            silence: cadence.silence,
            holdSilence: cadence.hold,
            maxWait: cadence.maxWait,
            echoGrace: echoGrace,
            endpointTick: endpointTick,
            cadenceMargin: cadence.cadenceMargin,
            cadenceCeiling: cadence.cadenceCeiling,
            politeSilence: cadence.polite,
            emptyListensBeforeParking: cadence.emptyListensBeforeParking
        )
    }

    // MARK: - User intents

    /// The recogniser itself failed — not the mic refusing to open (that's the
    /// throwing `startListening` path) but a stream that opened and then ended
    /// without a word because the engine underneath couldn't start. Park with
    /// the reason on screen. Without this door every such failure counted as
    /// an empty listen and the loop re-armed into the same wall every ~170ms
    /// until it parked silently: "nothing is being captured", and the only
    /// witness was the unified log (2026-09-03, the simulator's "Failed to
    /// initialize recognizer"). Adapters call this BEFORE finishing the stream
    /// so the pending listen is cancelled rather than counted.
    public func listenFailed(_ message: String) {
        lastError = message
        Self.log.error("voice recogniser failed, parking: \(message, privacy: .public)")
        dispatch(.mute)
    }

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

    /// The OS took the audio session (a call, headphones pulled): park from
    /// any active state. The in-flight turn is held, not cancelled — its
    /// answer lands in the transcript unspoken. `begin()` re-arms.
    public func pause() {
        dispatch(.pause)
    }

    public func exit() {
        dispatch(.exit)
    }

    /// Wire from the speech provider's onSpeakingEnded.
    public func speechDidEnd() {
        dispatch(.speechFinished)
    }

    /// Wire from the speech provider's onSpeakingStarted. Purely a timing mark
    /// — the loop's state machine already owns the speaking phase, so this
    /// deliberately dispatches no event. It is the ONLY point that knows when
    /// sound actually reached the user, which is the number the whole voice
    /// performance thread is about.
    public func speechDidStart() {
        timeline.audioStarted(at: .now)
        flushTimelineIfSettled()
    }

    // MARK: - Reducer plumbing

    private func dispatch(_ event: VoiceLoopEvent) {
        // The machine arbitrates FIRST: two independent endpoint sources exist
        // (silence tick, recognizer finality) and the machine's state guard is
        // what drops the stale duplicate. Timing must follow that verdict, not
        // race ahead of it — a stale `.endpointed` acted on here would flush
        // the in-flight turn's timeline mid-turn and orphan its marks (PR #120
        // review). Every rejected event returns an empty command list; every
        // accepted `.endpointed` arm a non-empty one (pinned in
        // VoiceLoopMachineTests.staleEndpointReturnsNothing).
        let commands = machine.handle(event)
        state = machine.state
        recordTiming(for: event, accepted: !commands.isEmpty)
        for command in commands {
            execute(command)
        }
    }

    /// Stamp this turn's latency marks off the events already flowing through
    /// `dispatch`. Timing lives here rather than at each call site so a new
    /// route into the loop can't silently stop being measured.
    ///
    /// `.endpointed` is the user's own stopwatch start — but it also fires for
    /// empty/parked listens, which never run a turn; `summary()` returns nil for
    /// those, so they cost a mark and log nothing.
    ///
    /// `accepted` is the machine's verdict on the event; only `.endpointed`
    /// consults it (its flush is destructive, and only the machine knows which
    /// of the two endpoint sources counted). The answer events keep recording
    /// regardless — some accepted arms legitimately return no commands.
    private func recordTiming(for event: VoiceLoopEvent, accepted: Bool) {
        let now = ContinuousClock.now
        switch event {
        case .endpointed:
            // A rejected endpoint is the stale twin from the other source —
            // acting on it would flush the LIVE turn's timeline mid-turn.
            guard accepted else { return }
            // Flush FIRST: a previous turn that never settled (generated but
            // never spoke) would otherwise donate its first-sentence mark to
            // this turn and report a latency that belongs to neither.
            flushTimeline()
            timeline.endpointed(at: now)
        case .answerChunk:
            timeline.chunkReady(at: now)
        case .answerReady:
            // The whole-answer path has exactly one "sentence" and finishes
            // generating at the same instant it produces it.
            timeline.chunkReady(at: now)
            timeline.completed(at: now)
        case .answerCompleted:
            timeline.completed(at: now)
            flushTimelineIfSettled()
        case .answerFailed:
            // A failed turn's latency is worth MORE than a successful one's —
            // it is time the user waited for nothing. Reported unsettled.
            timeline.completed(at: now)
            flushTimeline()
        case .exit, .interrupt, .mute, .pause:
            // A barge-in, exit, or audio interruption mid-answer would otherwise
            // lose the turn's numbers entirely, biasing every measurement
            // towards the turns the user was patient enough to sit through.
            flushTimeline()
        case .begin, .partial, .speechFinished:
            break
        }
    }

    /// Log + clear once every number has landed.
    private func flushTimelineIfSettled() {
        guard timeline.isSettled else { return }
        flushTimeline()
    }

    /// Log whatever this turn managed to record, then start clean. `.notice`
    /// because `.info`/`.debug` do not persist in OSLogStore.
    private func flushTimeline() {
        defer { timeline.reset() }
        guard let summary = timeline.summary() else { return }
        lastTurnLatency = summary
        Self.log.notice("\(summary, privacy: .public)")
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
            timeline.turnStarted(at: .now)
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
                let knownPause = endpointer.observedPause
                endpointer.ingest(partial: accumulator.text, at: ContinuousClock.now)
                // Breadcrumb for the next "it cut me off" report: how patient the
                // loop has learned to be is the first thing you'd want to know,
                // and it's otherwise invisible. .notice because .info/.debug do
                // not persist in OSLogStore (our own logged lesson).
                if endpointer.observedPause > knownPause {
                    Self.log.notice(
                        "voice cadence: speaker pauses up to \(String(describing: self.endpointer.observedPause), privacy: .public) — waiting longer before taking a turn"
                    )
                }
                dispatch(.partial(accumulator.text))
            }
            // Stream ended (recognizer finality, an error, or a silent listen
            // under keepsListening). If a silence endpoint already moved the
            // machine on, this event is stale and dropped there. Logged so the
            // trail always names WHO ended a turn — this unconditional branch
            // is exactly where Apple Speech's own VAD used to take the user's
            // turn invisibly (2026-08-15 finding).
            guard !Task.isCancelled else { return }
            Self.log.notice("voice endpoint: recognizer ended the stream")
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
                if let decision = endpointer.decision(at: ContinuousClock.now) {
                    // Which branch took the turn, and how patient it was — the
                    // first question in every "it cut me off" report. `.notice`
                    // because `.info`/`.debug` do not persist in OSLogStore.
                    Self.log.notice("\(decision.logLine, privacy: .public)")
                    dispatch(.endpointed(sanitizedUtterance()))
                    return
                }
            }
        }
    }
}
