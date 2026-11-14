//
//  MLXBrainProvider+TextReading.swift
//  M1K3MLX
//
//  The read on the resident MLX brain: the look's session shape (instructions
//  only, thinking off, a capped answer, no persona prefix, never the cache)
//  with no image. Any MLX brain can read; Lil and Big both conform.
//
//  The window is a speed choice, not the model's limit: Qwen3.5-4B holds far
//  more, but the phone prefills at about 460-490 tokens a second
//  (docs/evals/2026-11-09-vision-ttft-iphone/), so every 1,000 tokens of text
//  is about two seconds before the first word there.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-14, Confidence 0.7 (the session shape
//  is the look's, which is measured; the windows are starting points).
//  Prior: none (new file); MLXBrainProvider+ImageLooking.swift is the template.
//  Review: Kev + claude-opus-5.5, 2026-11-14 — the windows are the blind set's fast pick: 4,096 on the Mac
//  (Lil 49/53 in 4.1 s against 47/53 in a 12 s first text at 8,192), 2,560 on the phone.
//  Open: Lil at 2,560 is unmeasured, and no read has been timed on the phone.
//

import Foundation
import M1K3Inference
import MLXLMCommon

extension MLXBrainProvider: TextReading {
    /// The read's fast window per platform (`ReadBudget`'s sweep note says why).
    static func readWindow(isPhone: Bool) -> Int {
        isPhone ? ReadBudget.fastPhoneMLXWindow : ReadBudget.fastMacMLXWindow
    }

    public var readContextTokens: Int {
        #if os(iOS) || os(visionOS)
            Self.readWindow(isPhone: true)
        #else
            Self.readWindow(isPhone: false)
        #endif
    }

    public func read(instructions: String, prompt: String) -> LookStream {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    let system = try TextReadingError.instructions(instructions)
                    try await GenerationActivity.shared.during("M1K3 read") {
                        let container = try await ensureLoaded()
                        defer { MLXMemoryBudget.reclaim(label: "read") }
                        var parameters = generateParameters
                        parameters.maxTokens = min(parameters.maxTokens ?? ReadBudget.answerTokens, ReadBudget.answerTokens)
                        let session = ChatSession(container, instructions: system, generateParameters: parameters)
                        if let context = Self.captionAdditionalContext(supportsThinkingToggle: supportsThinkingToggle) {
                            session.additionalContext = context
                        }
                        var answer = ""
                        for try await event in session.streamDetails(to: prompt, images: [], videos: []) {
                            try Task.checkCancellation()
                            if let piece = event.chunk, !piece.isEmpty {
                                answer += piece
                                continuation.yield(answer)
                            }
                            if let info = event.info {
                                logGenerationInfo(info, label: "read", model: modelIdentifier)
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
