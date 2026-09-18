//
//  GemmaVisionSpike.swift
//  M1K3MLX
//
//  SPIKE (2026-07-14): does gemma-4-e4b's vision tower actually work on-device,
//  and what does an image really cost? MLXLLM's Gemma4Model strips vision
//  weights at load (`vision_tower`/`vision_embedder`/`multi_modal_projector` —
//  see MLXBrainProvider's LLMModelFactory path); only MLXVLM's separate Gemma4
//  implementation consumes UserInput.images. Both factories load the SAME HF
//  checkpoint (mlx-community/gemma-4-e4b-it-4bit) into a common ModelContainer
//  ChatSession is agnostic to, so this probes the VLM load path directly — NO
//  change to the production MLXBrainProvider/InferenceProvider seam.
//
//  Answers three questions before any protocol design:
//    1. Does it load + generate a sane image description at all?
//    2. What's the REAL per-image prompt-token cost (measured, not the
//       ~256/280 default-`imageSeqLength` ballpark)?
//    3. Peak RAM with the vision tower resident — the 7.4GB figure in
//       docs/MODEL_CHOICES.md was measured on the STRIPPED (text-only) load.
//
//  Not wired into BrainTier/MLXBrainProvider. Isolated on purpose — the
//  project's own doctrine (docs/MODEL_CHOICES.md): "existence ≠ loadability ≠
//  quality. Verify each stage."
//
//  Signed: Kev + claude-sonnet-5, 2026-07-14, Confidence 0.5 (spike; compiles,
//  on-device run pending), Prior: Unknown
//  Review: claude-fable-5, 2026-07-14 — the on-device run HAPPENED same day:
//  e4b FAILS to load under MLXVLM (keyNotFound layers.24.self_attn.v_proj —
//  upstream Gemma4 VLM lacks the KV-shared-layer sanitize fix; e4b has 18
//  shared layers, 12B has 0); gemma-4-12B-it-4bit loads + describes the M1K3
//  app icon correctly, 265 prompt tokens/image, 7333MB peak. Confidence now
//  0.9 for the instrument itself (measured live, results in PR #39).

import Foundation
import MLXLMCommon
import MLXVLM

public enum GemmaVisionSpike {
    public struct Result: Sendable {
        public let baselineAnswer: String
        public let baselinePromptTokens: Int
        public let visionAnswer: String
        public let visionPromptTokens: Int
        /// visionPromptTokens - baselinePromptTokens — the measured per-image
        /// cost against THIS question length, not a generic per-image constant
        /// (the vision soft-token block is fixed-size, but the surrounding text
        /// prompt differs between the two turns).
        public let imageTokenCost: Int
        public let ramSnapshot: String
    }

    public enum SpikeError: Error, Sendable {
        /// The stream finished without ever yielding a `.info` event — the
        /// model produced no completion metadata, so we can't report a token
        /// count (treat as a probe failure, not a silent zero).
        case noPromptInfo
    }

    /// Default probe target. e4b has 18 cross-layer-KV-shared layers (per
    /// docs/MODEL_CHOICES.md) — MLXVLM's Gemma4 loader may not carry the same
    /// "KV-shared layers have no k_proj/v_proj/k_norm" fix MLXLLM's got
    /// (mlx-swift-lm #330/#342). Override via `modelID:` to probe a variant
    /// with different KV-sharing geometry (e.g. gemma-4-12B-it-4bit, which has
    /// ZERO KV-shared layers per the 06-24 bake-off).
    public static let defaultModelID = "mlx-community/gemma-4-e4b-it-4bit"

    /// Load `modelID` through MLXVLM (NOT the production MLXLLM path), ask the
    /// same short question with and without `imageURL` attached, and report
    /// the measured token delta + a RAM snapshot with the vision tower
    /// resident. Two full loads worth of generation on one container — the
    /// container is loaded once and reused for both turns.
    public static func run(
        imageURL: URL,
        modelID: String = defaultModelID,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Result {
        let configuration = VLMModelFactory.shared.configuration(id: modelID)
        let container = try await VLMModelFactory.shared.loadContainer(
            from: HubApiDownloader.llmDefault,
            using: TransformersTokenizerLoader(),
            configuration: configuration
        ) { prog in
            progress(prog.fractionCompleted)
        }

        let baselineQuestion = "In one short sentence, what is a hydraulic seal?"
        let (baselineText, baselineTokens) = try await generate(
            container: container, prompt: baselineQuestion, images: []
        )

        let visionQuestion = "In one short sentence, describe what you see in this image."
        let (visionText, visionTokens) = try await generate(
            container: container, prompt: visionQuestion, images: [.url(imageURL)]
        )

        return Result(
            baselineAnswer: baselineText,
            baselinePromptTokens: baselineTokens,
            visionAnswer: visionText,
            visionPromptTokens: visionTokens,
            imageTokenCost: visionTokens - baselineTokens,
            ramSnapshot: MLXMemoryBudget.snapshotDescription(label: "vision spike (VLM-loaded, tower resident)")
        )
    }

    /// One turn on a fresh `ChatSession` over the shared container — a fresh
    /// session per turn so the second call's prompt-token count is this turn's
    /// full render, not a KV-cache-trimmed delta.
    private static func generate(
        container: ModelContainer, prompt: String, images: [UserInput.Image]
    ) async throws -> (text: String, promptTokens: Int) {
        let session = ChatSession(container)
        var text = ""
        var promptTokens: Int?
        for try await event in session.streamDetails(to: prompt, images: images, videos: []) {
            if let chunk = event.chunk { text += chunk }
            if let info = event.info { promptTokens = info.promptTokenCount }
        }
        guard let tokens = promptTokens else { throw SpikeError.noPromptInfo }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), tokens)
    }
}
