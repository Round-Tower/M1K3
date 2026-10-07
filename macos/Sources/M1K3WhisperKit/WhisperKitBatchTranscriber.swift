//
//  WhisperKitBatchTranscriber.swift
//  M1K3WhisperKit
//
//  Batch (file → segments) transcription via WhisperKit — the engine the
//  M1K3Calls `BatchTranscriptionProvider` seam was built for. Records-then-
//  processes: a finished `.caf`/audio URL in, timestamped `CallTranscriptSegment`s
//  out, feeding the SAME `CallIntelligencePipeline` the transcript-import path
//  already proves. The Gemma-4 E4B shadow provider drops in behind the same seam.
//
//  Split, as everywhere in this package: the WhisperKit/CoreML call is a thin
//  verify-by-launch adapter (needs a downloaded model + a real file); the segment
//  MAPPING — trim, strip special tokens, drop non-speech markers, order — is a
//  pure static func, unit-tested without a model.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-07, Confidence 0.7,
//  Prior: internal call-pipeline project, WhisperKit-batch (Kev) — re-pointed at M1K3's
//  file-based BatchTranscriptionProvider seam; buffer/PowerEfficiency surface dropped.
//  Review: claude-opus-4-8, 2026-06-09 — single-flight the model load through
//  SingleFlightLoader to kill a check-then-act double-download race (a Settings
//  preload racing the first transcribe could start two ~142MB downloads). Confidence 0.8.
//  Review: Kev + claude-opus-5-5, 2026-10-07, Confidence 0.8 — WhisperKit 1.1: `@preconcurrency` dropped
//  (zero diagnostics without it); batch transcription owes a launch check with the voice check.

import Foundation
import M1K3Calls
import M1K3Inference
import M1K3Voice // TranscriptSanitizer (repetition collapse + tidy)

// No @preconcurrency under WhisperKit 1.x (re-checked 2026-10-07) — see WhisperKitProvider.
import WhisperKit

/// `@unchecked Sendable`: the loaded model is guarded by `lock`; WhisperKit's own
/// components are actor/queue-isolated. Mirrors `WhisperKitProvider` (live STT).
public final class WhisperKitBatchTranscriber: BatchTranscriptionProvider, @unchecked Sendable {
    public let name = "WhisperKit (batch)"

    private let lock = NSLock()
    private var whisperKit: WhisperKit?
    /// Coalesces concurrent model loads into one in-flight download. The loaded
    /// model is then cached in `whisperKit` for the sync `isAvailable`/`transcribe`
    /// reads the `BatchTranscriptionProvider` seam relies on.
    private let loader: SingleFlightLoader<LoadedWhisperKit>
    /// Kept so `isModelDownloaded` can probe the on-disk cache without an instance
    /// of the live provider.
    private let model: String
    private let downloadBase: URL?

    /// - Parameter model: WhisperKit variant. `base.en` (~142MB) balances size and
    ///   accuracy; batch transcription is latency-tolerant, so `small.en` is a fine
    ///   sharper upgrade. Can share a variant with the live provider's cache.
    /// - Parameter downloadBase: Root URL for model storage. Should match the live
    ///   `WhisperKitProvider`'s base so both share the same cached weights.
    public init(model: String = "base.en", downloadBase: URL? = nil) {
        self.model = model
        self.downloadBase = downloadBase
        loader = SingleFlightLoader { progress in
            progress(0.05)
            let config = WhisperKitConfig(model: model, verbose: false, prewarm: true, load: true)
            config.downloadBase = downloadBase
            return try LoadedWhisperKit(kit: await WhisperKit(config))
        }
    }

    /// Available only on Apple Silicon once a model has been loaded.
    public var isAvailable: Bool {
        #if arch(arm64)
            return lock.withLock { whisperKit != nil }
        #else
            return false
        #endif
    }

    /// Whether this transcriber's model weights are already cached on disk — probes
    /// the same path the live `WhisperKitProvider` uses (shared cache). Lets a launch
    /// restore decide "reload, don't re-download" without coupling to the live
    /// provider instance.
    public var isModelDownloaded: Bool {
        WhisperKitProvider.isModelDownloaded(model: model, downloadBase: downloadBase)
    }

    /// Download + load the WhisperKit model, reporting coarse progress. Idempotent.
    /// Concurrent callers share ONE load via the loader; the result is cached for
    /// the sync reads.
    public func prepareModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        if lock.withLock({ whisperKit != nil }) { progress(1.0); return }
        let loaded = try await loader.value(progress: progress)
        lock.withLock { whisperKit = loaded.kit }
        progress(1.0)
    }

    public func transcribe(fileURL: URL) async throws -> [CallTranscriptSegment] {
        guard let kit = lock.withLock({ whisperKit }) else {
            throw CallIntelligenceError.noTranscriberAvailable
        }
        let results: [TranscriptionResult]
        do {
            results = try await kit.transcribe(audioPath: fileURL.path)
        } catch {
            throw CallIntelligenceError.transcriptionFailed(error.localizedDescription)
        }
        let spans = results.flatMap(\.segments).map {
            (start: TimeInterval($0.start), text: $0.text)
        }
        return Self.makeSegments(from: spans)
    }

    // MARK: - Pure mapping (unit-tested)

    /// Turn WhisperKit's timed spans into ordered, cleaned `CallTranscriptSegment`s:
    /// strip special tokens, trim, drop empties + whole-bracket non-speech markers,
    /// sort by start time. Speaker attribution is left to the DiarizationAligner.
    public static func makeSegments(
        from spans: [(start: TimeInterval, text: String)]
    ) -> [CallTranscriptSegment] {
        spans
            .map { (start: $0.start, text: cleanSegment($0.text)) }
            .filter { !$0.text.isEmpty }
            .sorted { $0.start < $1.start }
            .map { CallTranscriptSegment(text: $0.text, startTime: $0.start) }
    }

    /// Strip WhisperKit `<|…|>` special tokens, trim, and treat a whole-bracket
    /// non-speech marker (`[BLANK_AUDIO]`, `[Music]`) as empty. Brackets embedded in
    /// real speech (`words [pause] more`) are preserved.
    ///
    /// Deliberately NARROWER than `WhisperTranscriptText.clean` (which strips every
    /// `[…]` anywhere): call transcripts can carry meaningful bracketed notation, so
    /// only a segment that is *entirely* a marker is dropped. The live STT path wants
    /// the wholesale strip — see `WhisperTranscriptText.clean` for why.
    private static func cleanSegment(_ raw: String) -> String {
        let stripped = WhisperTranscriptText.stripSpecialTokens(raw)
        if stripped.range(of: "^\\[[^\\[\\]]*\\]$", options: .regularExpression) != nil {
            return ""
        }
        // Collapse recogniser repetition + tidy whitespace. Pleasantries are KEPT
        // (dropPleasantries: false) — a spoken "thank you" is genuine call content.
        return TranscriptSanitizer.clean(stripped, dropPleasantries: false)
    }
}
