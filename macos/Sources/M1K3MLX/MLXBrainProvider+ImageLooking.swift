//
//  MLXBrainProvider+ImageLooking.swift
//  M1K3MLX
//
//  The streamed look on the resident MLX brain (#768): the caption seam's
//  session shape (instructions only, thinking off, a short cap, no persona
//  prefix slot because it never touches the cache), yielding the answer as it
//  is written instead of returning it whole.
//
//  Why this and not the chat send: an image in a tool-turn transcript vetoes
//  the cached persona prefix, so Lil re-prefilled ~4,000 tokens and took 9 s to
//  first text on the iPhone 17 Pro. This route prefills about 200 tokens plus
//  the frame: 0.56-0.91 s (docs/evals/2026-11-09-vision-ttft-iphone/).
//
//  Signed: Kev + claude-fable-5.2, 2026-11-09, Confidence 0.75 (the policy is
//  pinned; the vision round-trip is verify-by-launch, timed on the phone).
//  Prior: none (new file); the session shape is MLXBrainProvider+ImageCaptioning's.

import Foundation
import M1K3Inference
import MLXLMCommon

extension MLXBrainProvider: ImageLooking {
    /// A look is a sentence or two, spoken aloud as often as read.
    static let lookMaxTokens = 160

    /// The provider's own cap may shorten a look; nothing lengthens it.
    static func lookMaxTokens(providerCap: Int?) -> Int {
        min(providerCap ?? lookMaxTokens, lookMaxTokens)
    }

    /// The system turn of a look. NEVER the persona: blank instructions are the
    /// caller's bug and fail loudly.
    static func lookInstructions(_ text: String) throws -> String {
        try ImageLookingError.instructions(text)
    }

    public func look(image: ImageAttachment, instructions: String, prompt: String) -> LookStream {
        guard supportsImageInput else {
            return AsyncThrowingStream { $0.finish(throwing: ImageLookingError.cannotLook) }
        }
        return AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    let system = try Self.lookInstructions(instructions)
                    try await GenerationActivity.shared.during("M1K3 look") {
                        let container = try await ensureLoaded()
                        defer { MLXMemoryBudget.reclaim(label: "look") }
                        var parameters = generateParameters
                        parameters.maxTokens = Self.lookMaxTokens(providerCap: parameters.maxTokens)
                        let session = ChatSession(container, instructions: system, generateParameters: parameters)
                        if let context = Self.captionAdditionalContext(supportsThinkingToggle: supportsThinkingToggle) {
                            session.additionalContext = context
                        }
                        var answer = ""
                        let events = session.streamDetails(to: prompt, images: [.url(image.url)], videos: [])
                        for try await event in events {
                            try Task.checkCancellation()
                            if let piece = event.chunk, !piece.isEmpty {
                                answer += piece
                                continuation.yield(answer)
                            }
                            if let info = event.info {
                                logGenerationInfo(info, label: "look", model: modelIdentifier)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
