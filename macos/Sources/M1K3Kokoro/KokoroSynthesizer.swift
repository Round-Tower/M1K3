//
//  KokoroSynthesizer.swift
//  M1K3Kokoro
//
//  The neural synthesis core: text → phoneme tokens (KokoroG2P) → MLX inference on
//  the staged Kokoro weights (config.json + model.safetensors) with the per-length
//  voice style (KokoroVoices) → mono float PCM @ 24 kHz.
//
//  An actor guards the load lifecycle, but the OS-blocking work — the weight-load
//  and the per-chunk forward pass — runs on `Task.detached`, NOT on the actor's
//  cooperative thread (blocking a cooperative-pool thread for seconds is the classic
//  Swift-concurrency starvation anti-pattern). Loading is single-flight via a stored
//  Task: concurrent callers await the same load rather than double-reading the model.
//
//  This is the verify-by-launch adapter (no `swift test` for live MLX/Metal
//  inference — the metallib wall, see `../../CLAUDE.md`); the pieces it composes —
//  G2P assembly, the npz style read, the token-boundary assembly — are pure +
//  unit-tested, and Phase-1 proved the (prior ORT) path matches the Python
//  reference at 0.999 correlation.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-09, Confidence 0.6, Prior: Unknown
//  Review: claude (PR #13) — hoisted blocking load/inference off the cooperative pool
//  via Task.detached + single-flight load Task. Confidence 0.7.
//  Review: Kev + claude-fable-5, 2026-06-11 — synthesizeStream: sentence-chunked
//  synthesis (SpeechChunker) with per-chunk word timelines; synthesize() now
//  concatenates the stream — the silent 510-token truncation is gone.
//  Confidence 0.8.
//  Review: Kev + claude-fable-5, 2026-07-18 — the ONNX Runtime backend replaced
//  with a pure-MLX one (the vendored StyleTTS2/Kokoro port under
//  `MLX/Vendored/`, MIT, Blaizzy/mlx-audio-swift): `Loaded` now holds a
//  `KokoroModel` instead of an `ORTEnv`/`ORTSession`; `infer` runs its forward
//  pass instead of an ORT `run()`. Every caller of this file, KokoroG2P,
//  KokoroVoices, and the actor/single-flight/Task.detached structure are
//  UNCHANGED — the vocab ids KokoroG2P emits were verified byte-for-byte
//  against the new weights' `config.json` vocab map before this port began
//  (punctuation ids 1–15, space=16, and every inflection-suffix phoneme id
//  the G2P hardcodes all match). This removes the onnxruntime dependency
//  entirely (the visionOS unlock — onnxruntime-swift-package-manager had no
//  xrOS slice). Confidence 0.75 (the pure/testable seams — token assembly,
//  weight-key sanitize — are red-first pinned; live synthesis is
//  verify-by-launch/SelfTest, the metallib wall blocks it under `swift test`).
//

import Foundation
import M1K3Voice
import MLX
import os

/// One synthesized piece of an utterance: its audio and the word timing for
/// exactly that audio. `timeline.text` is the FULL utterance text (ranges
/// already offset); times are relative to the CHUNK's own start — the playback
/// layer anchors them globally as it schedules.
public struct SynthesizedChunk: Sendable {
    public let samples: [Float]
    public let timeline: SpokenWordTimeline

    public init(samples: [Float], timeline: SpokenWordTimeline) {
        self.samples = samples
        self.timeline = timeline
    }
}

public actor KokoroSynthesizer {
    public struct SynthError: Error, CustomStringConvertible {
        public let description: String
    }

    /// Kokoro's native output sample rate.
    public static let sampleRate: Double = 24000

    /// Immutable loaded state. `@unchecked Sendable` is sound here: it is built once
    /// and never mutated after `init`, and every forward pass is funnelled through
    /// `inferenceQueue` — a SERIAL queue — so no two inferences ever run
    /// concurrently against the same `KokoroModel`. The per-chunk loop alone is NOT
    /// enough: actor reentrancy lets two overlapping `synthesizeStream` calls
    /// interleave at the awaits, so cross-call serialization must live at the
    /// resource, not in the loop (PR #58 review catch — the old ORT backend was
    /// immune because `run()` is documented thread-safe; mlx-swift makes no such
    /// promise for one model instance).
    private final class Loaded: @unchecked Sendable {
        let model: KokoroModel
        let voices: KokoroVoices
        let g2p: KokoroG2P
        /// All forward passes run here, serially, off the cooperative pool.
        let inferenceQueue = DispatchQueue(label: "app.m1k3.kokoro.inference", qos: .userInitiated)

        init(modelDirectory: URL, voicesURL: URL) throws {
            let fileManager = FileManager.default
            let configURL = modelDirectory.appendingPathComponent("config.json")
            let weightsURL = modelDirectory.appendingPathComponent("model.safetensors")
            guard fileManager.fileExists(atPath: configURL.path),
                  fileManager.fileExists(atPath: weightsURL.path),
                  fileManager.fileExists(atPath: voicesURL.path)
            else {
                throw SynthError(description: "model files not staged at \(modelDirectory.path)")
            }
            model = try KokoroModel.fromModelDirectory(modelDirectory)
            voices = try KokoroVoices(contentsOf: voicesURL)
            g2p = try KokoroG2P.bundled()
        }
    }

    private static let log = Logger(subsystem: "app.m1k3", category: "voice")

    private let modelDirectory: URL
    private let voice: String
    private var loaded: Loaded?
    private var loadTask: Task<Loaded, Error>?
    /// The graph is compiled once per process; a second warm would be pure cost.
    private var warmed = false

    public init(modelDirectory: URL, voice: String = "bm_daniel") {
        self.modelDirectory = modelDirectory
        self.voice = voice
    }

    /// Eagerly load the model/voices/dictionary (e.g. at voice-prepare time) so the
    /// first spoken utterance isn't gated on the ~326 MB session init — AND run
    /// one throwaway forward pass, because loading the weights was only half of
    /// what this method promised.
    ///
    /// MLX compiles its Metal kernels lazily on first use, so before this the
    /// very first sentence of every launch paid the whole pipeline warm-up
    /// while the user sat listening to nothing. The audio is discarded; the
    /// compiled kernels are what we're keeping.
    public func preload() async throws {
        let box = try await ensureLoaded()
        await warm(box)
    }

    /// One short forward pass to compile the graph. Errors are swallowed on
    /// purpose: the weights ARE loaded by the time this runs, so a warm failure
    /// must never demote M1K3 to the system voice — it would trade the whole
    /// neural voice for a lost optimisation.
    private func warm(_ box: Loaded) async {
        guard !warmed else { return }
        warmed = true
        let started = ContinuousClock.now
        let result = box.g2p.annotatedTokens(Self.warmPhrase)
        guard !result.tokens.isEmpty else { return }
        do {
            let style = try box.voices.style(voice: voice, tokenCount: result.tokens.count)
            let tokens = KokoroMLXInput.modelTokens(result.tokens)
            _ = try await withCheckedThrowingContinuation { continuation in
                box.inferenceQueue.async {
                    continuation.resume(with: Result {
                        try Self.infer(box, tokens: tokens, style: style, speed: 1.0)
                    })
                }
            }
            // Hoisted: interpolating a MEMBER into a Logger autoclosure is the
            // documented swiftformat landmine in this repo.
            let elapsedMS = started.duration(to: .now).wholeMilliseconds
            Self.log.notice(
                "kokoro warm: graph compiled in \(elapsedMS, privacy: .public)ms — the first spoken sentence no longer pays this"
            )
        } catch {
            Self.log.warning("kokoro warm skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Short, ordinary, and never heard. Real words (not silence) so the G2P,
    /// the style lookup and the decoder all take the same path a real sentence
    /// takes — a degenerate input can compile a different graph.
    private static let warmPhrase = "Hello."

    /// Synthesize `text` to mono float PCM @ 24 kHz. Empty result ⇒ nothing to say
    /// (all words out-of-vocabulary); the caller should fall back.
    ///
    /// Concatenates `synthesizeStream` — long text is sentence-chunked under the
    /// model's 510-token context, never truncated (the old single-pass cap
    /// silently dropped everything past ~150 words).
    public func synthesize(text: String, speed: Float = 1.0) async throws -> [Float] {
        var all: [Float] = []
        for try await chunk in synthesizeStream(text: text, speed: speed) {
            all.append(contentsOf: chunk.samples)
        }
        return all
    }

    /// Synthesize `text` chunk-by-chunk: sentence-aware pieces ≤ the model's
    /// 510-token context, each yielded with its word timeline as soon as its
    /// inference finishes — playback can start after the first sentence.
    public nonisolated func synthesizeStream(
        text: String,
        speed: Float = 1.0
    ) -> AsyncThrowingStream<SynthesizedChunk, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    try await self.produceChunks(text: text, speed: speed) {
                        continuation.yield($0)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    private func produceChunks(
        text: String,
        speed: Float,
        yield: @Sendable (SynthesizedChunk) -> Void
    ) async throws {
        let box = try await ensureLoaded()
        let ranges = SpeechChunker.chunkRanges(
            text,
            tokenCount: { box.g2p.annotatedTokens(String($0)).tokens.count },
            maxTokens: KokoroG2P.maxTokens
        )
        let fullText = text as NSString
        for range in ranges {
            try Task.checkCancellation()
            let chunkText = fullText.substring(with: NSRange(location: range.lowerBound, length: range.count))
            let result = box.g2p.annotatedTokens(chunkText)
            guard !result.tokens.isEmpty else { continue } // all-OOV chunk: no audio to time
            let style = try box.voices.style(voice: voice, tokenCount: result.tokens.count)
            let modelTokens = KokoroMLXInput.modelTokens(result.tokens)
            // Inference is OS-blocking (Metal dispatch + a synchronous host-side
            // eval); run it on the box's SERIAL inference queue — off the
            // cooperative pool AND safe against overlapping synthesizeStream
            // calls interleaving via actor reentrancy (see Loaded's doc).
            let samples = try await withCheckedThrowingContinuation { continuation in
                box.inferenceQueue.async {
                    continuation.resume(with: Result {
                        try Self.infer(box, tokens: modelTokens, style: style, speed: speed)
                    })
                }
            }
            let timeline = KokoroWordTiming.timeline(
                text: text,
                result: result,
                audioDuration: Double(samples.count) / Self.sampleRate,
                textOffset: range.lowerBound
            )
            yield(SynthesizedChunk(samples: samples, timeline: timeline))
        }
    }

    /// Single-flight load: the first caller creates the detached load Task and stores
    /// it; concurrent callers (actor reentrancy across the `await`) await the SAME task,
    /// so the model is read exactly once. The stored handle is cleared on
    /// failure so a later call can retry.
    private func ensureLoaded() async throws -> Loaded {
        if let loaded { return loaded }
        if let loadTask { return try await loadTask.value }

        let directory = modelDirectory
        let voicesURL = modelDirectory.appendingPathComponent("voices-v1.0.bin")
        let task = Task.detached(priority: .userInitiated) {
            try Loaded(modelDirectory: directory, voicesURL: voicesURL)
        }
        loadTask = task
        do {
            let box = try await task.value
            loaded = box
            loadTask = nil
            return box
        } catch {
            loadTask = nil
            throw error
        }
    }

    /// Pure MLX forward pass on the loaded model. Runs off-actor (see `synthesize`).
    private static func infer(_ box: Loaded, tokens: [Int32], style: [Float], speed: Float) throws -> [Float] {
        let inputIds = MLXArray(tokens).reshaped([1, -1])
        let refS = MLXArray(style).reshaped([1, style.count])
        let (audio, _) = box.model(inputIds: inputIds, refS: refS, speed: speed)
        return audio.reshaped([-1]).asArray(Float.self)
    }
}
