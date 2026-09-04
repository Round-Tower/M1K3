//
//  AppleSpeechTranscriber.swift
//  M1K3Voice
//
//  Live dictation via Apple's SFSpeechRecognizer + AVAudioEngine — system
//  frameworks, zero third-party dep, so this ships the speak→transcript→RAG loop
//  without a model download. On-device recognition is *required* (not just
//  preferred): M1K3 is on-device-only, so if the recogniser can't run offline we
//  report unavailable rather than silently sending audio to Apple's servers.
//
//  Yields the recogniser's *cumulative* best transcription per partial (matching
//  TranscriptAccumulator's "latest text wins" fold), then a final segment. The
//  whole class is verify-by-launch (needs a mic + Speech authorization), like
//  AVSpeechProvider — the pure pieces it feeds (segment, router, accumulator) are
//  unit-tested.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.7,
//  Prior: internal call-pipeline project, AppleSpeechTranscriber + LiveTranscriptionSession
//  (Kev) — collapsed to one live-session provider, cumulative text, on-device
//  forced, device-picker + call-domain fields dropped.
//  Review: Kev + claude-fable-5, 2026-07-16 (concurrency deep pass, findings
//  1/6/14/16) — sessions are now GENERATION-stamped. Three races closed:
//  (a) a stale recognition callback (cancel-error or late isFinal from a
//  superseded session) used to run stopListening against CURRENT state and
//  silently kill the fresh session; (b) a stop landing while begin() sat in the
//  TCC-authorization suspension let begin re-arm the engine afterwards — mic
//  hot after stop, no teardown path (the audit's worst voice finding); (c) a
//  consumer cancelling the stream (instead of pairing stopListening) leaked the
//  live mic. Now: start/stop each bump `generation` under `lock`;
//  stopListening(ifGeneration:) claims state atomically and stale callers
//  no-op; begin() re-checks liveness after every suspension and runs a
//  commit-point epilogue after engine.start(); onTermination(.cancelled) makes
//  consumer-cancel teardown structural. Verify-by-launch per this file's
//  convention (TCC dialog + real mic); the pure pieces stay unit-tested.
//  Confidence 0.8 — the interleavings are adversarially verified across three
//  rounds, not launch-tested; every AVFoundation/SFSpeech timing claim is static
//  reasoning per the metallib-wall convention. Full evidence in
//  macos/scratch/voice-session-audit-2026-07-16/.
//  Review: Kev + claude-fable-5, 2026-07-16 (round-3 metacognitive pass) — the
//  non-final result branch now generation-gates its continuation yield too,
//  matching the error branch and the WhisperKit onState sibling. A superseded
//  session's late partial (fired after a stop bumped `generation` but before its
//  finish() completed) could otherwise flicker a stale segment into the UI; the
//  yield is now skipped when `generation != self.generation`. Confidence 0.85 —
//  a mechanical symmetry fold matching an already-verified pattern.
//  Review: Kev + claude-fable-5, 2026-08-15 — recognizer finality is no longer
//  an unconditional end-of-listen: under FinalityPolicy.keepsListening (voice-
//  first), isFinal and no-speech errors on the LIVE session restart recognition
//  (fresh request+task, same generation, engine+tap untouched — the tap's
//  fresh-per-buffer request read is now load-bearing). Request config
//  centralised in makeRequest (+addsPunctuation, .dictation hint); non-final
//  confidence yields nil (Apple reports a meaningless 0.0 there). Confidence
//  0.8 — the restart glue is verify-by-launch per this file's convention; the
//  policy/accumulator halves are test-pinned.
//  Review: Kev + claude-fable-5, 2026-09-03 — `lastFailure`: the reason a
//  session ended without a word (auth, no recogniser, mic route, engine error),
//  generation-scoped, so a consumer can tell a failed listen from a silent one
//  instead of parking mutely. Found while chasing "nothing is captured" on the
//  iOS Simulator: it advertises on-device support and then fails every task
//  with "Failed to initialize recognizer" — and a simulator-only server
//  fallback was tried and REVERTED the same day: the server path dies with the
//  identical error the moment speech arrives. Apple's recogniser does not run
//  on the simulator at all; voice capture is device-only, and the loop now says
//  so on screen instead of parking mutely. The on-device floor is untouched.
//
//  Review: Kev + claude-fable-5.1, 2026-09-03 — the VPIO output bus gets a silent render source (mainMixerNode touched,
//  volume 0): the phone was throwing ~330 render errors a second on every listen with voice processing on. Verify-owed
//  by count on device (render err: -1 → 0); no behaviour change intended.
//  Review: Kev + claude-fable-5.1, 2026-09-04 (the double arm) — the
//  configuration-change handler no longer tears the tap down unconditionally:
//  `MicTapReinstallPolicy` compares the format the tap was installed at with the
//  format read back (keep / restart / reinstall), so the iPhone's same-format
//  notification ~0.5 s after the first arm stops bouncing the engine. Real route
//  changes (a new sample rate or channel count) reinstall exactly as before.

import AVFoundation
import Foundation
import os
import Speech

/// `@unchecked Sendable`, guarded by TWO locks with a fixed order
/// (`engineLock` outer, `lock` inner — never the reverse):
/// - `lock` guards the recognition state (`generation`, `request`, `task`,
///   `continuation`) and the audio-tap closure only appends to the (lock-held)
///   request.
/// - `engineLock` guards the shared `AVAudioEngine` and its `engineOwner: UInt64?`
///   ownership stamp: every engine mutation (install/start/teardown/route-change
///   reinstall) acts only if it still owns the engine for the current generation,
///   so a superseded session can never strip a successor's live tap. This second
///   lock is load-bearing for the whole session-lifetime race story — see the
///   `engineLock` declaration below for why it is deliberately separate from `lock`.
public final class AppleSpeechTranscriber: TranscriptionProvider, @unchecked Sendable {
    public let name = "Apple Speech"

    /// This provider owns its own `AVAudioEngine`, so we can put voice processing
    /// on the input node (see `enableVoiceProcessing`). WhisperKit's engine lives
    /// inside that package and cannot be reached, which is the whole reason the
    /// router needs to know the difference.
    public let attemptsEchoCancellation = true

    private static let log = Logger(subsystem: "app.m1k3", category: "stt")

    private let locale: Locale
    private let audioEngine = AVAudioEngine()
    private let lock = NSLock()
    /// Serialises engine teardown/reinstall (stop + removeTap + installTap)
    /// between `stopListening` and the route-change handler, which now run on
    /// different threads. SEPARATE from `lock` on purpose: the tap closure takes
    /// `lock`, so guarding `audioEngine.stop()` with it would re-introduce the
    /// inversion `stopListening` documents. The tap closure never takes this one.
    private let engineLock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var continuation: AsyncStream<TranscriptSegment>.Continuation?
    /// One-shot breadcrumb flag (guarded by `lock`): the mono-mixdown adapter
    /// failing soft on a >2-channel device is a silent-capture risk and must
    /// log — once, not at tap-callback rate.
    private var mixdownFallbackLogged = false
    /// Observes `.AVAudioEngineConfigurationChange` so a route flip (a Bluetooth
    /// mic connecting, or capture forcing the A2DP→HFP profile switch) reinstalls
    /// the tap on the NEW input format instead of leaving it deaf on the old one.
    private var configObserver: NSObjectProtocol?
    /// Session identity (guarded by `lock`). Bumped by every start AND stop, so a
    /// callback or in-flight `begin()` belonging to a superseded session can prove
    /// it is stale and no-op instead of tearing down (or arming) the wrong session.
    /// AsyncStream.Continuation is not Equatable and a nil-check can't distinguish
    /// "stopped" from "restarted", so the counter is the only correct identity.
    private var generation: UInt64 = 0
    /// This session's finality policy (guarded by `lock`, set at start). Under
    /// `.keepsListening`, recognizer-initiated finality restarts recognition
    /// instead of ending the listen — see FinalityPolicy.
    private var sessionFinality: FinalityPolicy = .endsListen
    /// Whether this session has yielded any non-empty text (guarded by `lock`).
    /// The restart gate: a listen that has captured nothing ends exactly as
    /// before, preserving the consumer's empty-listen parking.
    private var sessionHasText = false
    /// Which generation's tap is currently installed on the bus / engine armed
    /// (nil = idle). Guarded by `engineLock` — mutated and read ONLY inside an
    /// engineLock hold, alongside the engine op it authorizes. This is what makes
    /// the stale-cleanup paths (a superseded begin's unwind/epilogue, a stop for a
    /// session that already handed the mic on) safe: they tear the engine down
    /// only if they still own it, so they can never strip a successor's live tap
    /// or stop its running engine. The shared `AVAudioEngine` had session identity
    /// only in its state before; now it has an explicit owner.
    private var engineOwner: UInt64?
    /// The format the live tap was installed at — `engineLock`-guarded like
    /// `engineOwner`. The configuration-change handler compares it with the
    /// format read back to decide keep / restart / reinstall.
    private var installedTapFormat: MicTapFormat?
    /// Why the current/most recent session ended without a word, when the
    /// recogniser (not the caller) ended it — see `lastFailure`. Guarded by `lock`.
    private var lastFailureMessage: String?

    public init(locale: Locale = .current) {
        self.locale = locale
    }

    /// Available when a recogniser exists for the locale, is ready, and supports
    /// on-device recognition (our privacy floor). Authorization is requested at
    /// `startListening` time, not here.
    public var isAvailable: Bool {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { return false }
        return recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
    }

    /// Why the most recent listen ended without yielding a word, if the
    /// recogniser ended it: authorization refused, no recogniser for the locale,
    /// the mic route not ready, or the engine failing mid-listen. The stream
    /// itself can't say (AsyncStream is non-throwing), so the consumer reads
    /// this when a listen ends empty and decides whether that was silence or a
    /// failure worth putting on screen — until 2026-09-03 the simulator's
    /// "Failed to initialize recognizer" looked exactly like silence. Cleared
    /// when a new session starts; a superseded session can't overwrite it.
    public var lastFailure: String? {
        lock.withLock { lastFailureMessage }
    }

    /// Record why a session ended empty. Generation-scoped like every other
    /// late path here: a superseded begin()'s unwind must not write over the
    /// successor session's (clean) slate.
    private func recordFailure(_ message: String, ifGeneration expected: UInt64? = nil) {
        lock.withLock {
            if let expected, expected != generation { return }
            lastFailureMessage = message
        }
    }

    public func startListening() throws -> AsyncStream<TranscriptSegment> {
        try startListening(finality: .endsListen)
    }

    public func startListening(finality: FinalityPolicy) throws -> AsyncStream<TranscriptSegment> {
        stopListening()
        return AsyncStream { continuation in
            let generation = lock.withLock {
                self.generation &+= 1
                self.continuation = continuation
                self.sessionFinality = finality
                self.sessionHasText = false
                self.lastFailureMessage = nil
                return self.generation
            }
            // Consumer cancellation (task torn down without a paired
            // stopListening) must release the mic structurally. Gated on
            // .cancelled: .finished only ever originates from stopListening
            // itself, and the generation scope keeps a cancelled OLD consumer
            // from killing a newer session.
            continuation.onTermination = { [weak self] reason in
                if case .cancelled = reason { self?.stopListening(ifGeneration: generation) }
            }
            Task { await self.begin(continuation, generation: generation) }
        }
    }

    public func stopListening() {
        stopListening(ifGeneration: nil)
    }

    /// Tear down the CURRENT session — but only if it is still the session the
    /// caller belongs to. `nil` means "whatever is live now" (the public stop);
    /// a stale generation no-ops, so a superseded session's late callbacks can
    /// never kill their successor. Claiming also bumps `generation`, which is
    /// what invalidates an in-flight `begin()` (see its re-checks).
    private func stopListening(ifGeneration expected: UInt64?) {
        let claimed = lock.withLock {
            () -> (UInt64, SFSpeechAudioBufferRecognitionRequest?, SFSpeechRecognitionTask?,
                   AsyncStream<TranscriptSegment>.Continuation?, NSObjectProtocol?)? in
            if let expected, expected != generation { return nil }
            let claimedGeneration = generation
            generation &+= 1
            let captured = (claimedGeneration, request, task, continuation, configObserver)
            request = nil
            task = nil
            continuation = nil
            configObserver = nil
            return captured
        }
        guard let (claimedGeneration, request, task, continuation, observer) = claimed else { return }
        // Tear the engine down only if THIS claimed session still owns it — a
        // begin() that hasn't armed yet leaves ownership with an older/nil value,
        // so this no-ops and begin's own commit-point cleans up. Prevents a stop
        // from stripping a successor that armed in the gap. Engine ops run OUTSIDE
        // `lock`: `audioEngine.stop()` blocks on in-flight tap callbacks, which
        // take `lock` — holding it would be the inversion this file documents.
        teardownEngineIfOwner(claimedGeneration)
        if let observer { NotificationCenter.default.removeObserver(observer) }
        request?.endAudio()
        task?.cancel()
        continuation?.finish()
    }

    /// Tear down the engine + tap IFF `generation` still owns them (guarded by
    /// `engineLock`). A stale caller no-ops rather than killing the live session.
    private func teardownEngineIfOwner(_ generation: UInt64) {
        engineLock.withLock {
            guard engineOwner == generation else { return }
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            engineOwner = nil
            installedTapFormat = nil
        }
    }

    // MARK: - Private

    /// Request authorization, then wire the mic into a streaming recognition
    /// request. On any failure the stream simply finishes (the caller sees no
    /// segments and can surface "couldn't start listening").
    ///
    /// Runs off-actor from an unstructured Task, so a stop (or a restart) can
    /// land at ANY suspension — most dramatically while `authorized()` sits in
    /// the system TCC dialog for seconds. Every step therefore re-proves the
    /// session is still current before touching shared engine state, and the
    /// commit-point epilogue after `engine.start()` re-checks once more: without
    /// it, a stop landing between the task store and the start left the mic
    /// recording with no owner and no teardown path.
    private func begin(
        _ continuation: AsyncStream<TranscriptSegment>.Continuation,
        generation: UInt64
    ) async {
        // supportsOnDeviceRecognition is part of the guard, not just the
        // request config: the file's privacy floor is on-device REQUIRED, and
        // a recogniser that can't run offline must read unavailable rather
        // than fall through to a request that could reach Apple's servers
        // (review fold, #129 — previously only `isAvailable` was re-checked
        // here and in restartRecognition).
        guard await Self.authorized() else {
            recordFailure(
                "Speech recognition isn't allowed — check Settings › Privacy & Security.",
                ifGeneration: generation
            )
            continuation.finish()
            return
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition
        else {
            recordFailure("Speech recognition isn't available right now.", ifGeneration: generation)
            continuation.finish()
            return
        }

        let request = Self.makeRequest(recognizer: recognizer)
        // Store the request before installing the tap (so the first audio buffers
        // aren't dropped by `self.request` still being nil when the tap fires) —
        // atomically with the liveness re-check: a stop that landed during the
        // authorization suspension already bumped the generation, and a stale
        // begin must not clobber a successor session's request.
        let stillCurrent = lock.withLock {
            guard generation == self.generation else { return false }
            self.request = request
            // Re-arm the mixdown-fallback breadcrumb per SESSION: this object
            // is an app-lifetime singleton, so a launch-scoped flag would log
            // the first fallback ever and then go silent for every later
            // session — on this device or any other (post-merge review, #127).
            self.mixdownFallbackLogged = false
            return true
        }
        guard stillCurrent else {
            // Never touch the engine here: a newer session may own it.
            continuation.finish()
            return
        }

        // A Bluetooth mic engaging (or TCC settling) can leave the input format
        // degenerate at this instant; refuse a dead tap rather than capture
        // silence. The route-change observer below reinstalls once it's ready.
        // Installing also CLAIMS engine ownership for this generation (under
        // engineLock, atomically with the install) so every later teardown can
        // check it. A stale generation never installs.
        guard installTapAsOwner(generation) else {
            Self.log.error("mic input route not ready or session superseded — not listening")
            recordFailure("The microphone isn't ready yet.", ifGeneration: generation)
            stopListening(ifGeneration: generation)
            continuation.finish()
            return
        }
        observeConfigurationChanges(ifGeneration: generation)

        let task = makeRecognitionTask(
            recognizer: recognizer, request: request,
            generation: generation, continuation: continuation
        )

        let taskAccepted = lock.withLock {
            guard generation == self.generation else { return false }
            self.task = task
            return true
        }
        guard taskAccepted else {
            // A stop claimed the session while the recognition task was being
            // created: unwind this begin()'s pieces. teardownEngineIfOwner only
            // touches the engine if WE still own it — if the claiming stop (or a
            // successor) already took ownership, this no-ops, so we never strip a
            // successor's tap.
            task.cancel()
            request.endAudio()
            teardownEngineIfOwner(generation)
            continuation.finish()
            return
        }

        // Start the engine only while we still own it (guarded inside engineLock);
        // a stop that claimed us between the task store and here already flipped
        // ownership, so startEngineIfOwner no-ops and the epilogue finishes us.
        switch startEngineIfOwner(generation) {
        case .notOwner:
            // A newer session owns the engine; just release our non-engine pieces.
            request.endAudio()
            task.cancel()
            continuation.finish()
            return
        case .failed:
            stopListening(ifGeneration: generation)
            continuation.finish()
            return
        case .started:
            break
        }

        // COMMIT-POINT EPILOGUE: the engine is now RUNNING and we owned it through
        // the start. If a stop claimed the session in the gap between the start
        // and this check, its teardownEngineIfOwner may have run BEFORE we set
        // ownership (no-op then) — so tear our own engine down now. Guarded by
        // ownership, so if a successor has since armed, we leave it alone.
        //
        // A racing stopListening for THIS generation may have already called
        // endAudio()/cancel()/finish() on these same request/task/continuation
        // objects. The double call is INTENTIONAL and safe: the engine stop is
        // deduplicated by the ownership check in teardownEngineIfOwner, and
        // endAudio()/cancel()/finish() are each idempotent (the standard defensive
        // idiom) — so the two teardown paths coincide harmlessly rather than
        // needing a single serialised owner of the non-engine pieces too.
        let staleAfterStart = lock.withLock { generation != self.generation }
        if staleAfterStart {
            teardownEngineIfOwner(generation)
            request.endAudio()
            task.cancel()
            continuation.finish()
        }
    }

    /// One recognition request, configured in ONE place so a mid-listen restart
    /// can't drift from the session's original settings. `addsPunctuation` +
    /// `.dictation` are deliberate (2026-08-15): punctuated partials give
    /// UtteranceCompleteness a real terminal-punctuation signal (previously the
    /// hold branch could barely engage on this engine), and the dictation hint
    /// biases the recognizer toward long-form speech.
    private static func makeRequest(recognizer: SFSpeechRecognizer) -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.addsPunctuation = true
        request.taskHint = .dictation
        return request
    }

    /// The recognition callback, shared by the initial task and every
    /// mid-listen restart. Non-final confidence is yielded as nil — Apple
    /// reports a meaningless 0.0 on non-final segments, and folding that into
    /// the sanitizer's gate read as "measured zero" rather than "unknown".
    private func makeRecognitionTask(
        recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        generation: UInt64,
        continuation: AsyncStream<TranscriptSegment>.Continuation
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            // Generation-scoped on BOTH exits: stopListening endAudio()s then
            // cancel()s the old task, so a superseded session comes back as a
            // late isFinal OR a cancel-error — either used to tear down the NEW
            // session's engine/tap/continuation. Only Apple's benign no-speech
            // error routes through the restart decision like isFinal (silence
            // wearing an error type); every OTHER error ends the listen and is
            // logged — a revoked authorization or broken model must not be
            // masked as segment-boundary churn (review fold, #129).
            if let error {
                self.recognizerReachedFinality(
                    generation: generation, continuation: continuation, error: error
                )
                return
            }
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            // Generation-gate the SHARED continuation exactly as the error branch
            // above (and the WhisperKit sibling's onState) do: a superseded session's
            // late, non-final partial must not flicker into a continuation the
            // consumer has already asked to finish. Without this the two providers
            // are asymmetric in precisely the dimension this hardening pass unifies.
            // isFinal still routes through the generation-scoped decision below.
            let isCurrent = self.lock.withLock {
                guard generation == self.generation else { return false }
                if !text.isEmpty { self.sessionHasText = true }
                return true
            }
            if isCurrent, !text.isEmpty {
                continuation.yield(TranscriptSegment(
                    text: text,
                    isFinal: result.isFinal,
                    confidence: result.isFinal ? Self.confidence(of: result.bestTranscription) : nil
                ))
            }
            if result.isFinal {
                self.recognizerReachedFinality(generation: generation, continuation: continuation)
            }
        }
    }

    /// The recognizer declared finality on its own — isFinal (error nil) or a
    /// recognition error. Under `.keepsListening` with captured text, benign
    /// finality (isFinal / the no-speech error) is a SEGMENT boundary, not the
    /// end of the listen — restart recognition and keep the engine, tap, and
    /// stream open. A genuine error, or anything else, ends the listen exactly
    /// as before (a stale generation no-ops inside stopListening) — with the
    /// error logged either way, so a hard failure finally leaves its name in
    /// the trail instead of a stream of identical restarts.
    private func recognizerReachedFinality(
        generation: UInt64,
        continuation: AsyncStream<TranscriptSegment>.Continuation,
        error: Error? = nil
    ) {
        let (isCurrent, wantsRestart) = lock.withLock {
            (generation == self.generation,
             sessionFinality.shouldRestart(hasCapturedText: sessionHasText))
        }
        let benign = error.map(RecognizerFinality.isBenignNoSpeech) ?? true
        if let error, isCurrent, !benign {
            let reason = error.localizedDescription
            Self.log.error("recognizer failed mid-listen — ending: \(reason, privacy: .public)")
            recordFailure(reason, ifGeneration: generation)
        }
        guard isCurrent, benign, wantsRestart else {
            stopListening(ifGeneration: generation)
            return
        }
        restartRecognition(generation: generation, continuation: continuation)
    }

    /// Swap in a fresh request + recognition task under the SAME session: the
    /// engine and tap keep running, and the tap reads `self.request` fresh per
    /// buffer, so audio flows into the new request the moment it is stored.
    /// The accumulator's commit-and-continue fold makes the restarted session's
    /// from-empty cumulative partials safe downstream.
    private func restartRecognition(
        generation: UInt64,
        continuation: AsyncStream<TranscriptSegment>.Continuation
    ) {
        guard let recognizer = SFSpeechRecognizer(locale: locale),
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition
        else {
            // Say WHY before ending: the controller's stream-end line can't
            // distinguish this from a normal single-segment end, and
            // unexplained turn-endings are the bug this whole file exists to
            // end (round-2 review).
            Self.log.error("on-device recognizer unavailable at segment restart — ending listen")
            recordFailure("Speech recognition became unavailable.", ifGeneration: generation)
            stopListening(ifGeneration: generation)
            return
        }
        let request = Self.makeRequest(recognizer: recognizer)
        let previous = lock.withLock {
            () -> SFSpeechAudioBufferRecognitionRequest?? in
            guard generation == self.generation else { return nil }
            let old = self.request
            self.request = request
            return .some(old)
        }
        guard let previous else { return } // superseded while deciding — the stop owns teardown
        previous?.endAudio()
        Self.log.notice("recognizer finalized mid-listen — restarting recognition, turn stays open")
        let task = makeRecognitionTask(
            recognizer: recognizer, request: request,
            generation: generation, continuation: continuation
        )
        let accepted = lock.withLock {
            guard generation == self.generation else { return false }
            self.task = task
            return true
        }
        if !accepted {
            task.cancel()
            request.endAudio()
        }
    }

    /// Install this session's tap AND claim engine ownership atomically under
    /// `engineLock`. Refuses (false) if the session is already superseded or the
    /// mic route isn't ready (degenerate format). Installing a fresh tap first
    /// drains any stale one on the bus (idempotent), so a leftover tap can't
    /// collide.
    private func installTapAsOwner(_ generation: UInt64) -> Bool {
        engineLock.withLock {
            guard lock.withLock({ generation == self.generation }) else { return false }
            audioEngine.inputNode.removeTap(onBus: 0)
            guard installInputTap() else { return false }
            engineOwner = generation
            return true
        }
    }

    private enum EngineStartOutcome { case started, notOwner, failed }

    /// Prepare + start the engine IFF `generation` owns it (guarded by
    /// `engineLock`). On failure it relinquishes ownership so a retry/route-change
    /// can re-arm cleanly.
    private func startEngineIfOwner(_ generation: UInt64) -> EngineStartOutcome {
        engineLock.withLock {
            guard engineOwner == generation else { return .notOwner }
            audioEngine.prepare()
            do {
                try audioEngine.start()
                return .started
            } catch {
                audioEngine.inputNode.removeTap(onBus: 0)
                engineOwner = nil
                installedTapFormat = nil
                return .failed
            }
        }
    }

    /// Install the mic tap against the CURRENT input format, refusing a
    /// degenerate 0-Hz / 0-channel format — an unsettled route (Bluetooth mic
    /// still engaging, TCC not yet granted). Installing a tap with that format
    /// invalidates the HAL AudioUnit (-10877) and captures nothing. Returns
    /// false when the route isn't ready, so the caller can wait for the
    /// route-change observer to reinstall.
    @discardableResult
    private func installInputTap() -> Bool {
        let inputNode = audioEngine.inputNode
        // BEFORE reading the format: voice processing CHANGES it (VPIO renders
        // mono at the device rate), so a format read first would install a tap
        // that no longer matches the node.
        enableVoiceProcessing(on: inputNode)
        // Give the I/O unit's OUTPUT element a render source. With voice
        // processing on, the engine's I/O unit is a VPIO whose output bus
        // renders every cycle regardless; with nothing attached to
        // `outputNode`, that render fails — the phone logged
        // `AURemoteIO … render err: -1` ~330×/s through every listen, think
        // and speak phase (2026-09-03, iPhone 17 Pro; the Mac's log shows
        // none). Touching `mainMixerNode` implicitly connects mixer → output;
        // an input-less mixer renders silence, so the bus is satisfied and
        // nothing audible changes. Volume 0 is belt-and-braces.
        audioEngine.mainMixerNode.outputVolume = 0
        let format = inputNode.outputFormat(forBus: 0)
        Self.log.notice(
            "stt mic input format \(format.sampleRate, privacy: .public)Hz ch=\(format.channelCount, privacy: .public)"
        )
        guard MicTapFormatGate.isUsable(
            sampleRate: format.sampleRate, channelCount: format.channelCount
        ) else {
            Self.log.error("degenerate mic format — not installing tap (route not ready)")
            installedTapFormat = nil
            return false
        }
        // The closure reads `self?.request` FRESH per buffer rather than closing
        // over the request live at install time — now LOAD-BEARING (2026-08-15):
        // a mid-listen recognition restart (FinalityPolicy.keepsListening) swaps
        // `self.request` under the running tap, and fresh-per-buffer reads are
        // exactly what routes audio into the new request without touching the
        // engine. Residual (pre-existing): removeTap(onBus:) is not guaranteed
        // to synchronously drain an in-flight render-thread callback, so a
        // trailing buffer from a just-removed tap could theoretically append a
        // few stray samples into a successor session's request; not observed in
        // practice.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            // Multi-channel devices go MONO before the recognizer: SFSpeech
            // accepts >2-channel buffers and silently never produces a partial
            // (the 2026-08-14 nine-channel aggregate — VPIO above doesn't
            // engage on aggregates, so the tap sees the raw device format).
            guard let self else { return }
            // Skip the mixdown copy when no session wants the audio — the
            // `self` check alone can't do that (this object is an app-lifetime
            // singleton; sessions are generation-scoped, and it's the nil'd
            // request that marks teardown — post-merge review, #127).
            guard self.lock.withLock({ self.request != nil }) else { return }
            let audible = MonoMixdown.mixIfNeeded(buffer)
            self.lock.withLock {
                // The adapter fails SOFT (returns the original buffer) if it
                // can't build the mono copy — which would re-open the exact
                // listens-captures-nothing class this fix closes. Leave a
                // breadcrumb, once per session (PR #127 review).
                if audible === buffer, buffer.format.channelCount > 2, !self.mixdownFallbackLogged {
                    self.mixdownFallbackLogged = true
                    Self.log.error(
                        """
                        mono mixdown fell back — recognizer fed \
                        \(buffer.format.channelCount, privacy: .public)-channel audio \
                        (silent-capture risk)
                        """
                    )
                }
                self.request?.append(audible)
            }
        }
        installedTapFormat = MicTapFormat(sampleRate: format.sampleRate, channelCount: format.channelCount)
        return true
    }

    /// Turn on Apple's voice-processing IO for this mic: acoustic echo
    /// cancellation, noise suppression and AGC, plus speech-triggered ducking of
    /// whatever else is playing.
    ///
    /// Why it matters (Kev, 2026-08-11): with music on, M1K3 and the music "both
    /// compete as opposed to ducking", and the recogniser hears the room —
    /// including M1K3's own voice, which `echoGrace` can only paper over by
    /// waiting. VPIO's reference signal is the OUTPUT device, so it cancels
    /// anything coming out of the speakers (the music and M1K3 alike) rather than
    /// just muting us in time.
    ///
    /// `enableAdvancedDucking` ducks other audio only while it detects the user
    /// SPEAKING, which is the behaviour asked for — the music stays listenable
    /// and gets out of the way mid-sentence, instead of being flattened for the
    /// whole session.
    ///
    /// Non-fatal by design: VP is unavailable on some aggregate/virtual input
    /// devices, and a plain mic tap is strictly better than no mic. Idempotent —
    /// the route-change handler reinstalls taps and must not re-toggle a live
    /// setting (toggling requires a stopped engine).
    private func enableVoiceProcessing(on inputNode: AVAudioInputNode) {
        guard !inputNode.isVoiceProcessingEnabled else { return }
        do {
            try inputNode.setVoiceProcessingEnabled(true)
            inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                    enableAdvancedDucking: true, duckingLevel: .max
                )
            Self.log.notice("stt voice processing on (echo cancellation + speech-triggered ducking)")
        } catch {
            // Worth a trail: this is the difference between "the mic hears the
            // room" and "the mic hears you", and it fails silently otherwise.
            Self.log.error(
                "stt voice processing unavailable — no echo cancellation or ducking on this input: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func observeConfigurationChanges(ifGeneration generation: UInt64) {
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: nil
        ) { [weak self] _ in
            self?.handleConfigurationChange(generation: generation)
        }
        // Store only while still the live session — a stale begin() must not
        // plant an observer the racing stop already can't see (it captured and
        // removed the PREVIOUS one when it claimed).
        let accepted = lock.withLock {
            guard generation == self.generation else { return false }
            self.configObserver = observer
            return true
        }
        if !accepted { NotificationCenter.default.removeObserver(observer) }
    }

    /// The engine posted a configuration change. Either a real route change (a
    /// Bluetooth mic connecting, or starting capture forcing the headset's
    /// A2DP→HFP profile switch) — the installed tap is bound to the OLD input
    /// format and now delivers nothing, so reinstall against the new format and
    /// restart — or the same-format notice the iPhone posts ~0.5 s after the
    /// first arm of a session (2026-09-03), where tearing the tap down bounced
    /// the engine for nothing. `MicTapReinstallPolicy` decides from the format
    /// the tap was installed at, the format read back, and whether the engine is
    /// still running (Apple's contract lets it stop itself before posting).
    /// Generation-scoped: an in-flight notification from a removed observer must
    /// not re-arm the engine for a session that has since been stopped
    /// (ownerless hot mic) or install a second tap into a starting successor (a
    /// crash). The whole decision runs under `engineLock` with the ownership
    /// check inside it, so it is atomic against every other engine op.
    private func handleConfigurationChange(generation: UInt64) {
        engineLock.withLock {
            // Only OUR session, still current, still the engine owner.
            guard engineOwner == generation,
                  lock.withLock({ generation == self.generation }) else { return }
            let readBack = audioEngine.inputNode.outputFormat(forBus: 0)
            let action = MicTapReinstallPolicy.action(
                installed: installedTapFormat,
                current: MicTapFormat(sampleRate: readBack.sampleRate, channelCount: readBack.channelCount),
                engineRunning: audioEngine.isRunning
            )
            switch action {
            case .keep:
                Self.log.notice("audio configuration notice — mic format unchanged, engine running; tap kept")
            case .restart:
                Self.log.notice("audio configuration notice — mic format unchanged, engine stopped; restarting")
                restartEngineAfterConfigurationChange()
            case .reinstall:
                Self.log.notice("audio route changed — reinstalling mic tap at the new format")
                audioEngine.inputNode.removeTap(onBus: 0)
                if audioEngine.isRunning { audioEngine.stop() }
                guard installInputTap() else {
                    // Route not ready yet; ownership stands so the next notification retries.
                    return
                }
                restartEngineAfterConfigurationChange()
            }
        }
    }

    /// Caller holds `engineLock`.
    private func restartEngineAfterConfigurationChange() {
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            Self.log.error(
                "engine restart after route change failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func authorized() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }

    /// Mean per-segment confidence (0...1), or nil when the recogniser reports none.
    private static func confidence(of transcription: SFTranscription) -> Float? {
        let segments = transcription.segments
        guard !segments.isEmpty else { return nil }
        return segments.reduce(0) { $0 + $1.confidence } / Float(segments.count)
    }
}
