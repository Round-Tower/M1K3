//
//  WhisperKitProvider.swift
//  M1K3WhisperKit
//
//  High-accuracy on-device transcription via WhisperKit (CoreML). Isolated in
//  its own target — like M1K3MLX — so only this target and the app link the heavy
//  CoreML/model machinery; M1K3Voice stays system-frameworks-only.
//
//  WhisperKit needs a model downloaded + loaded before it can serve, so
//  `isAvailable` is false until `prepareModel` succeeds — which means the router
//  uses Apple Speech out of the box and switches to WhisperKit once its model is
//  ready. Live mic streaming runs through WhisperKit's `AudioStreamTranscriber`,
//  whose `currentText` is cumulative (matching TranscriptAccumulator's fold).
//
//  Verify-by-launch: model download + mic streaming need a real device + the mic
//  entitlement; the seam it plugs into (router, accumulator) is unit-tested.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.6,
//  Prior: internal call-pipeline project, WhisperKitProvider (Kev) — re-pointed at M1K3's live
//  TranscriptionProvider seam + AudioStreamTranscriber (the prior call-pipeline's was buffer-pump),
//  ModelManaged/PowerEfficiency surface dropped.
//  Review: claude-opus-4-8, 2026-06-09 — single-flight the model load through
//  SingleFlightLoader to kill the same check-then-act double-download race as the
//  batch transcriber. Confidence 0.8.
//  Review: Kev + claude-fable-5, 2026-07-16 (concurrency deep pass, findings
//  2/13/14/19) — restart races closed STRUCTURALLY. The root cause was that every
//  AudioStreamTranscriber wrapped the SAME `kit.audioProcessor` (one shared engine
//  slot), so any streamer's `stopStreamTranscription()` tore down whichever
//  session currently held the mic — a fire-and-forget old-stop could kill the new
//  session's capture, and a stale callback could kill a live successor. An
//  adversarial verify pass (3 lenses) showed a generation-guard + "belt" could not
//  make the shared processor safe. Fix: each session builds its OWN
//  `AudioProcessor()` (the constructor already accepts one), so `stopRecording()`
//  is session-scoped and cross-session capture damage is impossible. Generation
//  stamping remains for the SHARED transcript state (a stale onState must not write
//  `lastText` — which the next session's stop emits as its final segment, the
//  "previous utterance re-sent as a fresh turn" bug — nor finish a successor's
//  continuation) AND now drives a per-session SELF-STOP: `startStreamTranscription`
//  suspends at an XPC mic-permission hop on EVERY start (not just first launch), so a
//  stop landing in that window spends the provider's one fire-and-forget teardown on
//  a not-yet-armed engine, and the session would then record FOREVER (hot mic to app
//  quit + unbounded audio buffer) with no reference left to stop it. Fix: the first
//  state callback after the engine arms re-checks generation FIRST — before the
//  empty-text guard, so the placeholder-text zombie is caught — and self-stops its
//  OWN streamer, safe precisely because each session owns its processor. A 2-round
//  adversarial verify pass (6 lenses) drove this: the self-stop belt was WRONG on the
//  shared processor (it killed live successors) and CORRECT on the per-session one.
//  Verify-by-launch per this file's header. Confidence 0.8 — three adversarial-verify
//  rounds, not launch-tested; upstream WhisperKit timing taken on faith per the
//  metallib-wall convention. Evidence in macos/scratch/voice-session-audit-2026-07-16/.

import AVFoundation
#if os(macOS)
    // The HAL property API in defaultInputChannelCount (AudioObjectGetPropertyData
    // and friends). AVFoundation happens to re-export these today — verified
    // compiling without this line — but an implicit transitive dependency is
    // exactly the kind that breaks on an SDK bump. Explicit > implicit.
    import CoreAudio
#endif
import Foundation
import M1K3Inference
import M1K3Voice
import os

// @preconcurrency is LOAD-BEARING here (checked 2026-07-16): removing it yields
// real `sending` diagnostics on AudioStreamTranscriber construction (non-Sendable
// AudioEncoding/TextDecoding/tokenizer). Re-check on the next WhisperKit bump.
@preconcurrency import WhisperKit

/// `@unchecked Sendable`: WhisperKit + the active streamer/continuation are
/// guarded by `lock`; WhisperKit's own components are actor/queue-isolated.
public final class WhisperKitProvider: TranscriptionProvider, @unchecked Sendable {
    public let name = "WhisperKit"

    private static let log = Logger(subsystem: "app.m1k3", category: "stt")
    private let lock = NSLock()
    private var whisperKit: WhisperKit?
    private var streamer: AudioStreamTranscriber?
    private var continuation: AsyncStream<TranscriptSegment>.Continuation?
    private var lastText = ""
    /// Session identity (guarded by `lock`). Bumped by every start AND stop so a
    /// stale streamer's late callbacks — a zombie onState, a superseded start
    /// task's error path, a cancelled old consumer — can prove they're stale and
    /// no-op instead of polluting the shared transcript state or finishing the
    /// wrong continuation.
    private var generation: UInt64 = 0

    /// Per-session self-stop seam. Holds the session's own streamer (write-once,
    /// before `startStreamTranscription()` enables any callback) so a stale
    /// `onState` can stop ITS OWN capture — safe now that each session owns its
    /// AudioProcessor. `claimSelfStop()` fires at most once. This closes the
    /// zombie window: a stop landing inside `startStreamTranscription`'s permission
    /// suspension can't be reached by the provider's stop (it already spent its
    /// one fire-and-forget on a not-yet-armed engine), so the session would
    /// otherwise record forever; the first callback after it arms self-stops it.
    private final class StreamerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var streamer: AudioStreamTranscriber?
        private var stopClaimed = false
        var value: AudioStreamTranscriber? {
            lock.withLock { streamer }
        }

        func set(_ streamer: AudioStreamTranscriber) {
            lock.withLock { self.streamer = streamer }
        }

        func claimSelfStop() -> Bool {
            lock.withLock {
                if stopClaimed { return false }
                stopClaimed = true
                return true
            }
        }
    }

    /// Coalesces concurrent model loads into one in-flight download; the loaded
    /// model is cached in `whisperKit` for the sync `isAvailable`/`startListening`
    /// reads.
    private let loader: SingleFlightLoader<LoadedWhisperKit>

    private let model: String
    private let downloadBase: URL?
    private let inputChannelCount: @Sendable () -> UInt32?
    /// Last channel count the gate vetoed, so the veto logs once per device
    /// change instead of on every `isAvailable` read (guarded by `lock`).
    private var lastVetoLogged: UInt32?
    /// TTL cache over the device probe (guarded by `lock`). `channels` may be
    /// a cached nil (unreadable probe) — the tuple's presence, not the value,
    /// is what says "probed recently".
    private var cachedProbe: (channels: UInt32?, at: ContinuousClock.Instant)?
    /// Probe cache lifetime — long enough to take HAL I/O off the render-rate
    /// path, short enough that a device swap is honoured almost immediately.
    private static let probeTTL: Duration = .seconds(2)

    /// - Parameter model: WhisperKit variant. `base.en` balances size (~142MB)
    ///   and accuracy; `tiny.en` (~75MB) downloads faster, `small.en` is sharper.
    /// - Parameter downloadBase: Root URL for model storage. Pass the app's
    ///   Application Support directory so downloads land in a stable sandbox path
    ///   rather than the HuggingFace cache default (which can produce broken partial
    ///   downloads in sandboxed apps).
    /// - Parameter inputChannelCount: Probe for the default input device's channel
    ///   count (nil = unreadable, fails open). Injectable for tests; the default
    ///   reads the live device — see `ConverterChannelGate` for why this gates
    ///   availability at all.
    public init(
        model: String = "base.en",
        downloadBase: URL? = nil,
        inputChannelCount: (@Sendable () -> UInt32?)? = nil
    ) {
        self.model = model
        self.downloadBase = downloadBase
        self.inputChannelCount = inputChannelCount ?? Self.defaultInputChannelCount
        loader = SingleFlightLoader { progress in
            progress(0.05)
            let config = WhisperKitConfig(model: model, verbose: false, prewarm: true, load: true)
            config.downloadBase = downloadBase
            return try LoadedWhisperKit(kit: await WhisperKit(config))
        }
    }

    /// Whether the model's CoreML bundle is already on disk — the guard for
    /// auto-loading on launch WITHOUT risking a silent ~142MB re-download (mirrors
    /// Kokoro's `isModelStaged`). WhisperKit lays weights down at
    /// `<base>/models/argmaxinc/whisperkit-coreml/openai_whisper-<variant>/`; the
    /// AudioEncoder bundle's presence is the "complete, not half-fetched" signal.
    public var isModelDownloaded: Bool {
        Self.isModelDownloaded(model: model, downloadBase: downloadBase)
    }

    /// Static form so launch-migration code can ask "is variant X already on disk?"
    /// without constructing a provider. Same path contract as the instance read.
    public static func isModelDownloaded(model: String, downloadBase: URL?) -> Bool {
        guard let downloadBase else { return false }
        let bundle = downloadBase
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml/openai_whisper-\(model)")
            .appendingPathComponent("AudioEncoder.mlmodelc")
        return FileManager.default.fileExists(atPath: bundle.path)
    }

    /// Available only on Apple Silicon once a model has been loaded AND the
    /// current input device is one WhisperKit's converter can actually serve
    /// (≤2 channels — see `ConverterChannelGate`). Otherwise the router falls
    /// back to Apple Speech, which is the whole point: an honest false here is
    /// a working dictation session on the other engine; a dishonest true is
    /// the silent "Failed to create node format" loop of 2026-08-13.
    public var isAvailable: Bool {
        #if arch(arm64)
            return lock.withLock { whisperKit != nil } && inputDeviceUsable
        #else
            return false
        #endif
    }

    /// Whether the default input device can feed WhisperKit's mic converter.
    /// Separated from `isAvailable` so the device gate is testable without a
    /// loaded model. Logs the veto once per device change, not per read.
    ///
    /// TTL-cached (round-4 review, PR #124): `isAvailable` sits on a SwiftUI
    /// hot path — `canDictate` → router → here, re-evaluated at the chat's
    /// coalesced render rate for the whole of every streamed answer — and the
    /// default probe is two HAL round-trips through coreaudiod plus an alloc.
    /// Bounded staleness is fine: routing binds at listen START, so a device
    /// swap is honoured within a probe period either way.
    var inputDeviceUsable: Bool {
        let now = ContinuousClock.now
        let channels: UInt32?
        if let cached = lock.withLock({ cachedProbe }),
           cached.at.duration(to: now) < Self.probeTTL
        {
            channels = cached.channels
        } else {
            channels = inputChannelCount()
            lock.withLock { cachedProbe = (channels, now) }
        }
        let usable = ConverterChannelGate.canServe(channelCount: channels)
        let shouldLog: Bool = lock.withLock {
            if usable {
                lastVetoLogged = nil
                return false
            }
            guard lastVetoLogged != channels else { return false }
            lastVetoLogged = channels
            return true
        }
        if shouldLog, let channels {
            Self.log.notice(
                """
                whisperkit vetoed: input device has \(channels, privacy: .public) channels \
                (layoutless converter format needs 1-2) — router falls back to Apple Speech
                """
            )
        }
        return usable
    }

    /// Default probe: total input channels on the system default input device.
    /// CoreAudio property reads on macOS (cheap — no AVAudioEngine/HAL spin-up);
    /// the shared AVAudioSession on iOS. nil on any read failure (fails open).
    private static let defaultInputChannelCount: @Sendable () -> UInt32? = {
        #if os(macOS)
            var deviceID = AudioDeviceID(0)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
            ) == noErr, deviceID != kAudioObjectUnknown else { return nil }

            address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var configSize = UInt32(0)
            guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &configSize) == noErr,
                  configSize > 0 else { return nil }
            let raw = UnsafeMutableRawPointer.allocate(
                byteCount: Int(configSize), alignment: MemoryLayout<AudioBufferList>.alignment
            )
            defer { raw.deallocate() }
            guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &configSize, raw) == noErr
            else { return nil }
            let bufferList = UnsafeMutableAudioBufferListPointer(
                raw.assumingMemoryBound(to: AudioBufferList.self)
            )
            return bufferList.reduce(0 as UInt32) { $0 + $1.mNumberChannels }
        #else
            return UInt32(max(0, AVAudioSession.sharedInstance().inputNumberOfChannels))
        #endif
    }

    /// Download + load the WhisperKit model, reporting coarse progress (WhisperKit
    /// init bundles download + load). Idempotent: returns fast if already loaded.
    /// Concurrent callers share ONE load via the loader; the result is cached for
    /// the sync reads.
    public func prepareModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        if lock.withLock({ whisperKit != nil }) { progress(1.0); return }
        let loaded = try await loader.value(progress: progress)
        lock.withLock { whisperKit = loaded.kit }
        progress(1.0)
    }

    public func startListening() throws -> AsyncStream<TranscriptSegment> {
        guard let kit = lock.withLock({ whisperKit }), let tokenizer = kit.tokenizer else {
            throw WhisperKitProviderError.modelNotLoaded
        }
        stopListening()

        return AsyncStream { continuation in
            let generation = lock.withLock {
                self.generation &+= 1
                self.continuation = continuation
                self.lastText = ""
                return self.generation
            }
            // Consumer cancellation must release this session's capture
            // structurally; gated on .cancelled (.finished only originates from
            // stopListening) and generation-scoped so a cancelled OLD consumer
            // can't tear down a newer session.
            continuation.onTermination = { [weak self] reason in
                if case .cancelled = reason { self?.stopListening(ifGeneration: generation) }
            }

            let streamerBox = StreamerBox()

            // Yield cumulative text whenever WhisperKit's running transcription grows.
            // `clean` strips both `<|…|>` control tokens AND non-speech annotations
            // ([BLANK_AUDIO], [Music]…) — the latter were surviving into voice-first
            // and being sent to the model as if they were a spoken turn.
            let onState: AudioStreamTranscriberCallback = { [weak self] _, newState in
                guard let self else { return }
                let text = WhisperTranscriptText.clean(newState.currentText)
                // Generation FIRST, BEFORE the empty-text guard: a stale streamer's
                // very first callback (fired synchronously when isRecording flips
                // true, with placeholder/empty text) is how we catch a session that
                // armed AFTER its stop already ran — see the header's zombie note.
                // Such a session self-stops ITS OWN capture (safe: own processor),
                // rather than recording forever. A stale write to the SHARED
                // `lastText` is also blocked (the current session's stop would emit
                // it as a final segment — the re-sent-utterance bug).
                let action = self.lock.withLock { () -> OnStateAction in
                    guard generation == self.generation else { return .selfStop }
                    // "Waiting for speech..." is WhisperKit's pre-speech placeholder.
                    guard !text.isEmpty, text != "Waiting for speech..." else { return .ignore }
                    self.lastText = text
                    return .yield
                }
                switch action {
                case .selfStop:
                    if streamerBox.claimSelfStop() {
                        Task { await streamerBox.value?.stopStreamTranscription() }
                    }
                case .yield:
                    continuation.yield(TranscriptSegment(text: text, isFinal: false))
                case .ignore:
                    break
                }
            }

            let streamer = AudioStreamTranscriber(
                audioEncoder: kit.audioEncoder,
                featureExtractor: kit.featureExtractor,
                segmentSeeker: kit.segmentSeeker,
                textDecoder: kit.textDecoder,
                tokenizer: tokenizer,
                // A FRESH processor per session (not the shared kit.audioProcessor):
                // this session's stopRecording() then touches only THIS engine, so a
                // stale teardown can never kill a live successor's mic. The heavy
                // models above are stateless and safe to share. (Caveat: a future
                // MULTILINGUAL variant — no `.en` suffix, language: nil below — drives
                // WhisperKit's TextDecoder.detectLanguage, whose languageLogitsFilter
                // lazy-cache is not thread-safe under the deliberate stop/start decode
                // overlap; serialize sessions or pin language before adopting one.)
                audioProcessor: AudioProcessor(),
                // skipSpecialTokens defaults to false → tokens in the text; turn it on
                // (the stripper above is the belt-and-braces backstop). Pin language to
                // English for the monolingual `.en` models (skip wasted, misfire-prone
                // detection); a future multilingual variant (no `.en` suffix) gets nil
                // → auto-detect. Derived from the model id so it stays variant-correct.
                decodingOptions: DecodingOptions(
                    language: model.hasSuffix(".en") ? "en" : nil, skipSpecialTokens: true
                ),
                stateChangeCallback: onState
            )
            // Populate the self-stop box BEFORE the streamer can fire any callback
            // (callbacks only start inside startStreamTranscription, below).
            streamerBox.set(streamer)
            let accepted = lock.withLock {
                guard generation == self.generation else { return false }
                self.streamer = streamer
                return true
            }
            guard accepted else {
                // A stop claimed the session while the streamer was being built;
                // it captured (and finished) this continuation already, and the
                // never-started streamer needs no teardown.
                continuation.finish()
                return
            }

            Task {
                // A stop may have claimed the session between accept and here.
                guard self.lock.withLock({ generation == self.generation }) else { return }
                do { try await streamer.startStreamTranscription() }
                catch {
                    // Mid-session stream failure (CoreML hiccup, audio route change,
                    // decoder error) otherwise looks identical to a normal silence
                    // endpoint downstream — leave a trail before tearing down.
                    // Generation-scoped: a superseded session's failure must not
                    // finish its successor's continuation.
                    Self.log.error("stream transcription failed: \(error.localizedDescription, privacy: .public)")
                    self.stopListening(ifGeneration: generation)
                }
            }
        }
    }

    public func stopListening() {
        stopListening(ifGeneration: nil)
    }

    /// Tear down the CURRENT session — but only if it is still the session the
    /// caller belongs to (`nil` = whatever is live now). Claiming bumps the
    /// generation (so in-flight start tasks and stale callbacks no-op) and
    /// fire-and-forgets the streamer's teardown. That teardown touches only this
    /// session's OWN AudioProcessor, so ordering it against a concurrent
    /// startListening (a different processor) is unnecessary — the shared-engine
    /// hazard the old `pendingStop` chain guarded no longer exists.
    private func stopListening(ifGeneration expected: UInt64?) {
        let claimed = lock.withLock {
            () -> (AudioStreamTranscriber?, AsyncStream<TranscriptSegment>.Continuation?, String)? in
            if let expected, expected != generation { return nil }
            generation &+= 1
            let captured = (streamer, continuation, lastText)
            streamer = nil
            continuation = nil
            lastText = ""
            return captured
        }
        guard let (stopped, continuation, finalText) = claimed else { return }
        Task { await stopped?.stopStreamTranscription() }
        if let continuation {
            if !finalText.isEmpty {
                continuation.yield(TranscriptSegment(text: finalText, isFinal: true))
            }
            continuation.finish()
        }
    }
}

public enum WhisperKitProviderError: Error, Sendable {
    case modelNotLoaded
}

/// What a state-change callback should do once it has resolved its session's
/// currency under `lock`: self-stop a stale (possibly zombie) streamer, yield the
/// cleaned partial, or ignore a placeholder/empty update.
private enum OnStateAction {
    case selfStop
    case yield
    case ignore
}

/// `@unchecked Sendable` box so a loaded `WhisperKit` can cross the
/// `SingleFlightLoader` actor boundary. Justified for the same reason as the
/// providers' class-level annotation: WhisperKit's components are actor/queue-
/// isolated, and the instance is only handed straight into an NSLock-guarded
/// store on the far side — never mutated across threads.
struct LoadedWhisperKit: @unchecked Sendable {
    let kit: WhisperKit
}
