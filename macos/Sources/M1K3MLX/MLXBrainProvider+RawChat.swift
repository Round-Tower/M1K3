//
//  MLXBrainProvider+RawChat.swift
//  M1K3MLX
//
//  Lil and Big behind the Local API (`RawChatCompleting`): the caller's system
//  message as the whole system prompt, the earlier turns as the session's
//  history, the question as the turn. No persona, no cached persona prefix, no
//  tools, no conversation tail of M1K3's own.
//
//  Thinking is OFF on this route whatever the app's setting: an OpenAI client
//  has no place for a thought, and a budgeted thought with no opener would
//  arrive as answer text. A failure throws, so the server can say so instead of
//  streaming an empty success.
//
//  Verify-by-launch: MLX cannot run under `swift test`. The request shape and
//  the pure plan are tested; the generation itself is checked with a real
//  client against the built app.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-11, Confidence 0.7, Prior: none (new file)
//

import Foundation
import M1K3Inference
import MLXLMCommon

extension MLXBrainProvider: RawChatCompleting {
    /// What one raw chat runs with. A caller may shorten the answer, never
    /// lengthen it past this provider's cap; temperature is clamped to 0...2.
    static func rawChatParameters(
        base: GenerateParameters, defaultCap: Int, request: RawChatRequest
    ) -> GenerateParameters {
        var parameters = base
        let cap = parameters.maxTokens ?? defaultCap
        parameters.maxTokens = min(max(1, request.maxTokens ?? cap), cap)
        if let temperature = request.temperature {
            parameters.temperature = Float(min(max(0, temperature), 2))
        }
        return parameters
    }

    /// The earlier turns as the session's history.
    static func rawChatHistory(_ request: RawChatRequest) -> [Chat.Message] {
        request.earlier.map { $0.role == .user ? .user($0.content) : .assistant($0.content) }
    }

    public func completeRawChat(_ request: RawChatRequest) -> RawChatStream? {
        AsyncThrowingStream { continuation in
            let task = Task {
                await GenerationActivity.shared.during("M1K3 Local API") {
                    defer { MLXMemoryBudget.reclaim(label: "completeRawChat") }
                    do {
                        let container = try await ensureLoaded()
                        let parameters = Self.rawChatParameters(
                            base: generateParameters, defaultCap: Self.defaultMaxTokens, request: request
                        )
                        let session = ChatSession(
                            container, instructions: request.system, history: Self.rawChatHistory(request),
                            generateParameters: parameters
                        )
                        if let context = Self.captionAdditionalContext(supportsThinkingToggle: supportsThinkingToggle) {
                            session.additionalContext = context // thinking off, as a caption has it
                        }
                        var finish: RawChatFinish?
                        for try await event in session.streamDetails(to: request.question, images: [], videos: []) {
                            if let chunk = event.chunk, !chunk.isEmpty { continuation.yield(.delta(chunk)) }
                            if let info = event.info {
                                logGenerationInfo(info, label: "local-api", model: modelIdentifier)
                                finish = RawChatFinish(
                                    reason: info.stopReason == .length ? .length : .stop,
                                    promptTokens: info.promptTokenCount, completionTokens: info.generationTokenCount
                                )
                            }
                        }
                        try Task.checkCancellation()
                        continuation.yield(.finished(
                            finish ?? RawChatFinish(reason: .stop, promptTokens: nil, completionTokens: nil)
                        ))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
