//
//  MLXBrainProvider+ImageCaptioning.swift
//  M1K3MLX
//
//  Caption memory's generation seam (Stream D, 1.1 slice): an image in, a
//  neutral caption out, on the model that is already resident.
//
//  Why not the existing paths: `generate(prompt:)` is text-only, and the tool
//  turn session -- the only path that carries images -- seeds from the PERSONA
//  snapshot and never reads `InferenceIntent.instructions` (the persona-in-
//  utility trap). So this builds an upstream ChatSession whose system turn is
//  the instructions override and nothing else, sends the image with the prompt,
//  and forces thinking off (Qwen3.5 would otherwise think for ~13 s about a
//  whiteboard). The caller wraps it in `backgroundUtility`; it never builds or
//  takes a persona prefix slot because it never touches the cache.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-09, Confidence 0.75 (instructions and
//  thinking-off are pinned; the vision round-trip itself is verify-by-launch).
//  Prior: Unknown

import Foundation
import M1K3Inference
import MLXLMCommon

extension MLXBrainProvider: ImageCaptioning {
    /// A caption is a paragraph, not an essay.
    static let captionMaxTokens = 220

    /// The system turn of a caption session. NEVER the persona: a missing
    /// override is the caller's bug and fails loudly rather than leaking the
    /// persona into a stored caption.
    static func captionInstructions(override: String?) throws -> String {
        guard let text = override?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw InferenceError.generationFailed("a caption session needs neutral instructions")
        }
        return text
    }

    /// Thinking is OFF for a caption regardless of how the provider was built
    /// (`thinkingAdditionalContext` follows the chat setting; a caption must not).
    static func captionAdditionalContext(supportsThinkingToggle: Bool) -> [String: any Sendable]? {
        supportsThinkingToggle ? ["enable_thinking": false] : nil
    }

    public func caption(image: ImageAttachment, prompt: String) async throws -> String {
        guard supportsImageInput else {
            throw InferenceError.generationFailed("this model cannot read images")
        }
        let instructions = try Self.captionInstructions(override: InferenceIntent.instructions)
        return try await GenerationActivity.shared.during("M1K3 caption") {
            let container = try await ensureLoaded()
            defer { MLXMemoryBudget.reclaim(label: "caption") }
            var parameters = generateParameters
            parameters.maxTokens = min(parameters.maxTokens ?? Self.captionMaxTokens, Self.captionMaxTokens)
            let session = ChatSession(container, instructions: instructions, generateParameters: parameters)
            if let context = Self.captionAdditionalContext(supportsThinkingToggle: supportsThinkingToggle) {
                session.additionalContext = context
            }
            var raw = ""
            for try await event in session.streamDetails(to: prompt, images: [.url(image.url)], videos: []) {
                if let piece = event.chunk { raw += piece }
                if let info = event.info {
                    logGenerationInfo(info, label: "caption", model: modelIdentifier)
                }
            }
            return raw
        }
    }
}
