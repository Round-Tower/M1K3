//
//  KokoroSpeechProvider.swift
//  M1K3Kokoro
//
//  The premium "M1K3 Voice" tier — Kokoro, an offline neural TTS that runs fully
//  on-device. Isolated in its own target (like M1K3MLX / M1K3WhisperKit) so the
//  heavy ONNX runtime + grapheme→phoneme machinery the synthesis spike will add
//  never touches the core build.
//
//  THIS SESSION = the seam + the real download, NOT the synthesis kernel:
//    • `prepare(progress:)` genuinely downloads the Kokoro model + voices from the
//      public release into the app container, reporting real 0…1 progress — so the
//      whole download → ModelPreloading → ready UX is proven end-to-end and the
//      weights are staged on disk, ready for the spike.
//    • `speak(_:)` HONESTLY delegates to a private AVSpeech fallback for now. Audio
//      is still Apple's voice this session; the onboarding copy says "preparing the
//      neural voice", and nothing claims live neural synthesis. (Superseded — see
//      the 2026-06-11 review note below.)
//
//  The spike replaces ONLY the body of `synthesize(_:)` (phonemize → ONNX → PCM →
//  AVAudioPlayerNode) — every caller, the onboarding flow, and the seam are unchanged.
//
//  Signed: Kev + claude-sonnet-4-6, 2026-06-08, Confidence 0.55, Prior: Unknown
//  Review: Kev + claude-fable-5, 2026-06-11 — neural path now STREAMS chunks to
//  the renderer (speak(stream:)) with word timelines; Apple fallback only when
//  nothing was spoken at all; word-timing callbacks forwarded like lifecycle.
//  Confidence 0.8.
//  Review: Kev + claude-fable-5, 2026-07-16 (concurrency deep pass) — the
//  download path validated nothing: URLSession delivers HTTP 4xx/5xx as a
//  completed download, so an error body was staged as weights and the
//  file-existence fast path then trusted it forever (neural voice silently
//  dead, Apple fallback, no retry). Now: 2xx status gate in the delegate, a
//  plausibility floor that self-heals already-poisoned stages, and a
//  cancellation handler on the download await (all pinned in
//  KokoroDownloadValidationTests; the swallowed-preload-failure fallback
//  design is deliberately untouched).
//  Review: Kev + claude-fable-5, 2026-07-18 — the ONNX backend is gone
//  (KokoroSynthesizer.swift now runs pure MLX). Staging swaps the single
//  ~326 MB kokoro-v1.0.onnx for TWO files from `mlx-community/Kokoro-82M-bf16`:
//  `config.json` (tiny) + the weights (staged locally as `model.safetensors`,
//  matching what the vendored MLX loader expects — the HF repo's own
//  filename is `kokoro-v1_0.safetensors`, renamed on download to avoid yet
//  another hyphen/underscore footgun in this file). `voices-v1.0.bin` is
//  UNCHANGED — M1K3's own KokoroVoices npz reader stays, not the new repo's
//  per-voice `.safetensors` files.
//  Review: Kev + claude-sonnet-5, 2026-09-01 (issue #70) — `configURL`/
//  `modelURL` fetched an unpinned `main`, and nothing checked the bytes
//  before handing them to MLX (the same gap ADR 0002 closed for the two chat
//  brains + the retrieval embedder, explicitly left open here). Now both
//  resolve against `KokoroPinnedWeights.revision` (a pinned commit SHA) and
//  are verified against a digest manifest before `_ready` is ever set true —
//  a stale/tampered pre-existing file self-heals like the floor check
//  already did; a freshly downloaded file that still disagrees THROWS
//  (`KokoroWeightTamperError`) rather than silently retrying. `voices-v1.0.bin`
//  (a GitHub release, not HuggingFace) is unchanged — out of this pin's scope.
//  See `KokoroPinnedWeights.swift` for why this duplicates rather than
//  imports M1K3MLX's WeightIntegrity shape. Confidence 0.85.

import Foundation
import M1K3Inference
import M1K3LogCore
import M1K3Voice
import os

public final class KokoroSpeechProvider: SpeechProviderWithWordTiming, ModelPreloading, @unchecked Sendable {
    public let name = "kokoro"

    private static let log = M1K3Log.logger(.voice)

    /// The MLX Kokoro checkpoint (mlx-community/Kokoro-82M-bf16 — the model
    /// the passed synthesis spike validated bm_daniel against). `configURL`'s
    /// destination filename and `modelURL`'s BOTH stay as the HF repo names
    /// them; the weights are renamed on download to `model.safetensors` (see
    /// `prepare(progress:)`) — the vendored loader's expected name.
    ///
    /// Resolved against `KokoroPinnedWeights.revision` — a pinned commit SHA
    /// — rather than `main` (#70): both files are verified against a digest
    /// manifest below before `_ready` is ever set true, so an unpinned
    /// `main` that changed under us (or a compromised host) can no longer
    /// silently hand MLX arbitrary tensors.
    private static let configURL = URL(
        string: "https://huggingface.co/mlx-community/Kokoro-82M-bf16/resolve/\(KokoroPinnedWeights.revision)/config.json"
    )!
    private static let modelURL = URL(
        string: "https://huggingface.co/mlx-community/Kokoro-82M-bf16/resolve/\(KokoroPinnedWeights.revision)/kokoro-v1_0.safetensors"
    )!
    private static let voicesURL = URL(
        string: "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin"
    )!

    private let lock = NSLock()
    private var _ready = false
    /// Renders Kokoro's neural PCM (and the Apple-voice fallback) through M1K3's voice
    /// effect chain + playback. Concrete `EffectfulSpeechProvider`, not the protocol:
    /// the raw-PCM neural path needs `speak(rawPCM:)`, which the `SpeechProvider`
    /// protocol is too narrow to express.
    private let renderer: EffectfulSpeechProvider
    private let synthesizer: KokoroSynthesizer
    private let modelDirectory: URL

    public init(
        renderer: EffectfulSpeechProvider? = nil,
        modelDirectory: URL? = nil,
        voice: String = "bm_daniel"
    ) {
        let directory = modelDirectory ?? Self.defaultModelDirectory()
        self.modelDirectory = directory
        self.renderer = renderer ?? EffectfulSpeechProvider(chain: .m1k3Character)
        synthesizer = KokoroSynthesizer(modelDirectory: directory, voice: voice)
    }

    // MARK: - SpeechProvider

    /// Available only once the model is staged — so the router/swap won't select
    /// M1K3 Voice until `prepare` has succeeded.
    public var isAvailable: Bool {
        lock.withLock { _ready }
    }

    /// Whether all three staged files are already on disk — lets the app restore
    /// the M1K3 Voice tier on launch without kicking a fresh download.
    public var isModelStaged: Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: modelDirectory.appendingPathComponent("config.json").path)
            && fileManager.fileExists(atPath: modelDirectory.appendingPathComponent("model.safetensors").path)
            && fileManager.fileExists(atPath: modelDirectory.appendingPathComponent("voices-v1.0.bin").path)
    }

    public func speak(_ utterance: SpeechUtterance) async {
        await synthesize(utterance)
    }

    public func stop() async {
        await renderer.stop()
    }

    public func isSpeaking() async -> Bool {
        await renderer.isSpeaking()
    }

    // MARK: - Lifecycle callbacks (forwarded to the renderer so the avatar reacts)

    public var onSpeakingStarted: (@Sendable () -> Void)? {
        get { renderer.onSpeakingStarted }
        set { renderer.onSpeakingStarted = newValue }
    }

    public var onSpeakingEnded: (@Sendable () -> Void)? {
        get { renderer.onSpeakingEnded }
        set { renderer.onSpeakingEnded = newValue }
    }

    public var onTimelineReady: (@Sendable (SpokenWordTimeline) -> Void)? {
        get { renderer.onTimelineReady }
        set { renderer.onTimelineReady = newValue }
    }

    public var onWordSpoken: (@Sendable (Range<Int>) -> Void)? {
        get { renderer.onWordSpoken }
        set { renderer.onWordSpoken = newValue }
    }

    // MARK: - Synthesis

    /// Neural path: text → sentence chunks → G2P → MLX (config.json +
    /// model.safetensors) → mono PCM @ 24 kHz streamed to the renderer
    /// chunk-by-chunk, each with its word
    /// timeline — playback starts after the first sentence, long answers are never
    /// truncated, and the karaoke highlight tracks the audio. Falls back to the
    /// effect-processed Apple voice when nothing was spoken at all (model not
    /// staged, all-OOV text, ORT error before the first chunk); a mid-utterance
    /// failure ends the utterance with what was already scheduled instead of
    /// re-speaking it all in the fallback voice.
    private func synthesize(_ utterance: SpeechUtterance) async {
        let chunks = synthesizer.synthesizeStream(text: utterance.text)
        let timed = AsyncThrowingStream<TimedPCMChunk, Error> { continuation in
            let task = Task {
                do {
                    for try await chunk in chunks {
                        continuation.yield(TimedPCMChunk(samples: chunk.samples, timeline: chunk.timeline))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        let spoke = await renderer.speak(stream: timed, sampleRate: KokoroSynthesizer.sampleRate)
        if !spoke {
            await renderer.speak(utterance) // nothing phonemized/synthesized → Apple fallback
        }
    }

    // MARK: - ModelPreloading

    /// Stage the Kokoro weights into the app container, reporting real download
    /// progress. Idempotent — returns instantly once all three files are present.
    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        // Already staged this session — nothing to do. (The app layer also guards
        // concurrent calls via `isPreparingVoice`; this is the idempotent fast path.)
        if lock.withLock({ _ready }) {
            progress(1)
            return
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

        let configDest = modelDirectory.appendingPathComponent("config.json")
        let modelDest = modelDirectory.appendingPathComponent("model.safetensors")
        let voicesDest = modelDirectory.appendingPathComponent("voices-v1.0.bin")

        // Reclaim the retired ONNX model (~326 MB) from installs that predate the
        // MLX backend — nothing reads it anymore (PR #58 review suggestion).
        try? fileManager.removeItem(at: modelDirectory.appendingPathComponent("kokoro-v1.0.onnx"))

        // Self-heal a poisoned stage: a pre-status-check download could stage an
        // HTTP error body as weights, and file-existence alone would then trust
        // it forever (Apple-voice fallback with no retry path). An implausibly
        // small file is deleted here so the download blocks below re-fetch it.
        for (dest, floor) in [
            (configDest, KokoroDownloadValidation.configFloorBytes),
            (modelDest, KokoroDownloadValidation.modelFloorBytes),
            (voicesDest, KokoroDownloadValidation.voicesFloorBytes),
        ] where fileManager.fileExists(atPath: dest.path)
            && !KokoroDownloadValidation.isPlausibleStage(dest, floorBytes: floor)
        {
            Self.log.warning(
                "Kokoro staged file \(dest.lastPathComponent, privacy: .public) is implausibly small — discarding and re-downloading"
            )
            try? fileManager.removeItem(at: dest)
        }

        // #70: digest verification against the pinned HuggingFace manifest.
        // The floor check above only catches an obviously-wrong file (an
        // HTTP error body); a plausible-sized file whose BYTES were swapped
        // for something else entirely (a compromised host, a hijacked org
        // account, `main` moving under us before this pin existed) sails
        // through a size floor undetected. Runs every time `prepare()` is
        // called with `_ready` still false — i.e. once per app launch,
        // BEFORE the "already staged" fast path below is ever trusted — so a
        // cache poisoned on a previous run (or before this pin shipped)
        // cannot be silently trusted just because the files are already
        // there. Unlike M1K3MLX's WeightIntegrity (which never auto-heals a
        // digest mismatch on the multi-GB brains, by design), a PRE-EXISTING
        // mismatch self-heals here the same way the floor check above does:
        // Kokoro's own files are ~327 MB, not 6.7 GB, so re-fetching from the
        // pinned revision is cheap enough to be the right recovery, not just
        // an accepted risk. A mismatch on a FRESH download (just staged by
        // this same call) is treated more strictly below — see the throwing
        // check after the download blocks. `voices-v1.0.bin` is out of this
        // pin's scope (GitHub, not HF).
        for (dest, name) in [(configDest, "config.json"), (modelDest, "model.safetensors")]
            where fileManager.fileExists(atPath: dest.path) && !Self.matchesPinnedDigest(dest, name: name)
        {
            Self.log.fault(
                "Kokoro \(name, privacy: .public) does not match the pinned digest — discarding and re-downloading"
            )
            try? fileManager.removeItem(at: dest)
        }

        if fileManager.fileExists(atPath: configDest.path),
           fileManager.fileExists(atPath: modelDest.path),
           fileManager.fileExists(atPath: voicesDest.path)
        {
            lock.withLock { _ready = true }
            do {
                try await synthesizer.preload()
            } catch {
                // Apple-voice fallback is the intended recovery; the missing signal isn't.
                Self.log.warning("Kokoro preload failed: \(error.localizedDescription, privacy: .public)")
            }
            progress(1)
            return
        }

        // The weights are ~327 MB, voices ~28 MB, config.json a few KB — weight
        // the combined bar by size so it advances proportionally rather than
        // jumping at a file boundary.
        let configWeight = 0.01
        let modelWeight = 0.91
        let voicesWeight = 0.08

        // Tracks which of the two HF-pinned files this call ACTUALLY fetched,
        // so the post-download verification below only re-hashes bytes that
        // are new this call rather than re-checking ones the self-heal pass
        // already verified moments ago.
        var freshlyDownloaded: Set<String> = []

        if !fileManager.fileExists(atPath: configDest.path) {
            try await FileDownloader.download(Self.configURL, to: configDest) { fraction in
                progress(fraction * configWeight)
            }
            freshlyDownloaded.insert("config.json")
        }
        if !fileManager.fileExists(atPath: modelDest.path) {
            try await FileDownloader.download(Self.modelURL, to: modelDest) { fraction in
                progress(configWeight + fraction * modelWeight)
            }
            freshlyDownloaded.insert("model.safetensors")
        }
        if !fileManager.fileExists(atPath: voicesDest.path) {
            try await FileDownloader.download(Self.voicesURL, to: voicesDest) { fraction in
                progress(configWeight + modelWeight + fraction * voicesWeight)
            }
        }

        // #70: verify whatever we just downloaded against the pinned
        // digests BEFORE ever marking Kokoro ready. Unlike the self-heal
        // pass above (which silently discards a STALE pre-existing file so
        // the blocks above re-fetch it), a mismatch reaching THIS point
        // means the bytes we just downloaded from the pinned revision
        // disagree with the manifest RIGHT NOW — surfacing that as a thrown
        // error, rather than silently retrying inside this same call (which
        // would spin forever against a host serving the same bad bytes), is
        // the honest signal.
        for (dest, name) in [(configDest, "config.json"), (modelDest, "model.safetensors")]
            where freshlyDownloaded.contains(name) && !Self.matchesPinnedDigest(dest, name: name)
        {
            Self.log.fault(
                "Kokoro \(name, privacy: .public) does not match the pinned digest after downloading — refusing to use it"
            )
            throw KokoroWeightTamperError(file: name)
        }

        lock.withLock { _ready = true }
        do {
            try await synthesizer.preload()
        } catch {
            // Same as the on-disk path above: Apple-voice fallback is the intended
            // recovery, but a "neural voice ready" that then can't synthesise needs a signal.
            Self.log.warning("Kokoro preload failed: \(error.localizedDescription, privacy: .public)")
        }
        progress(1)
    }

    /// Whether the file at `dest` matches the digest pinned for `name`
    /// (`KokoroPinnedWeights`). Shared by both the pre-existing self-heal
    /// pass and the post-download throwing check, so the size+hash lookup
    /// exists in exactly one place.
    private static func matchesPinnedDigest(_ dest: URL, name: String) -> Bool {
        guard
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size]) as? Int64,
            let digest = KokoroPinnedWeights.sha256Digest(of: dest)
        else { return false }
        return KokoroPinnedWeights.matches(size: size, sha256: digest, file: name)
    }

    private static func defaultModelDirectory() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("M1K3/kokoro", isDirectory: true)
    }
}

// MARK: - Download validation

/// The two checks that keep a bad download from permanently bricking the neural
/// voice (2026-07-16 concurrency deep pass): URLSession delivers HTTP 4xx/5xx as
/// a COMPLETED download, so an error body would be staged as weights and
/// file-existence would trust it forever. Status validation stops future bad
/// stages; the plausibility floor also self-heals installs already poisoned.
enum KokoroDownloadValidation {
    /// Deliberately far below the real payloads (~327 MB weights, ~28 MB voices):
    /// the floors only need to reject staged HTML error pages (a few KB).
    static let modelFloorBytes: Int64 = 50 * 1024 * 1024
    static let voicesFloorBytes: Int64 = 1024 * 1024
    /// config.json itself is only a few KB, so this floor can't lean on a huge
    /// size margin the way the other two do — it exists purely to catch a
    /// zero-byte/truncated write. The HTTP status-code gate (`isAcceptable`,
    /// checked by the download delegate before ANY file is staged) is the
    /// real defense for config.json; this is defense-in-depth only.
    static let configFloorBytes: Int64 = 200

    /// HTTP responses must be 2xx; anything else (file://, nil) is not this
    /// check's concern and passes through.
    static func isAcceptable(_ response: URLResponse?) -> Bool {
        guard let http = response as? HTTPURLResponse else { return true }
        return (200 ..< 300).contains(http.statusCode)
    }

    static func isPlausibleStage(_ url: URL, floorBytes: Int64) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int64 else {
            return false
        }
        return size >= floorBytes
    }
}

/// The downloaded "weights" were an HTTP error body — surfaced instead of staged.
struct KokoroDownloadHTTPError: LocalizedError {
    let statusCode: Int
    var errorDescription: String? {
        "Kokoro download failed with HTTP status \(statusCode)"
    }
}

/// A file just downloaded from the pinned Kokoro revision does not match the
/// digest in `KokoroPinnedWeights` (#70) — thrown rather than silently
/// retried, so a live compromise or a very unlucky corruption on the fresh
/// download surfaces instead of spinning silently against the same source.
struct KokoroWeightTamperError: LocalizedError {
    let file: String
    var errorDescription: String? {
        "Kokoro's \(file) does not match the digest pinned for mlx-community/Kokoro-82M-bf16 — refusing to use it"
    }
}

// MARK: - Progress-reporting download

/// A small URLSession download wrapper that reports a 0…1 fraction and moves the
/// finished file to a destination. Lives here (not in the app) so the whole staging
/// path is in the isolated Kokoro target. `internal` (not private) so the
/// cancellation and staging contracts are pinned in KokoroDownloadValidationTests
/// via file:// URLs — no network in the suite.
///
/// `@unchecked Sendable` safety: the continuation lives behind `lock` and is
/// consumed by `takeContinuation()` — an atomic take-and-nil — so exactly one of
/// its resumers (the delegate callbacks on URLSession's serial queue, or the
/// cancellation handler on whatever thread cancellation lands) ever receives it.
/// Resume-exactly-once holds by construction, with NO dependency on URLSession
/// delivering a delegate callback for a task cancelled before resume().
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private let destination: URL
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    private init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    static func download(
        _ url: URL,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let downloader = FileDownloader(destination: destination, progress: progress)
        try await downloader.run(url)
    }

    /// Atomically claim the continuation: whoever takes it resumes it; everyone
    /// else sees nil and no-ops.
    private func takeContinuation() -> CheckedContinuation<Void, Error>? {
        lock.withLock {
            let taken = continuation
            continuation = nil
            return taken
        }
    }

    private func run(_ url: URL) async throws {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.downloadTask(with: url)
        // Cancellation-responsive without trusting delegate ordering: onCancel
        // claims the continuation itself, and the pre-cancelled entry path is
        // caught by the isCancelled check below — so a cancelled prepare never
        // rides out ~326 MB and the continuation can never leak, whatever
        // URLSession does with a task cancelled before resume().
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock { self.continuation = continuation }
                // onCancel may already have fired (a task cancelled before this
                // body ran) — it found no continuation to claim, so claim it here.
                if Task.isCancelled {
                    takeContinuation()?.resume(throwing: CancellationError())
                    return
                }
                task.resume()
            }
        } onCancel: {
            task.cancel()
            takeContinuation()?.resume(throwing: CancellationError())
        }
    }

    func urlSession(
        _: URLSession,
        downloadTask _: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten written: Int64,
        totalBytesExpectedToWrite expected: Int64
    ) {
        guard expected > 0 else { return }
        progress(min(max(Double(written) / Double(expected), 0), 1))
    }

    func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // URLSession treats HTTP 4xx/5xx as a COMPLETED download — without this
        // check the error body would be staged as model weights (and trusted by
        // every future launch). Fail loudly instead; nothing touches the disk.
        guard KokoroDownloadValidation.isAcceptable(downloadTask.response) else {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? -1
            takeContinuation()?.resume(throwing: KokoroDownloadHTTPError(statusCode: status))
            return
        }
        // Must move the temp file out synchronously — it's deleted when this returns.
        do {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: location, to: destination)
            takeContinuation()?.resume()
        } catch {
            takeContinuation()?.resume(throwing: error)
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            takeContinuation()?.resume(throwing: error)
        }
    }
}
