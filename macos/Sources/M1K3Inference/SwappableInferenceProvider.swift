//
//  SwappableInferenceProvider.swift
//  M1K3Inference
//
//  An InferenceProvider façade whose backing provider can change at runtime, so
//  switching the chosen brain's MLX model (Lil = Qwen ↔ Big = Gemma) re-points the
//  generation backend without rebuilding the RuntimeInferenceProvider / RAGResponder
//  that hold it. Lil and Big both route through RuntimeOption.mlxGemma, so this is
//  the single MLX slot behind that key; AppEnvironment sets the concrete model.
//
//  Mirrors SwappableEmbeddingService: a lock-protected swap so this Sendable type
//  reads safely off the main actor while the @Observable UI drives the change.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-08, Confidence 0.8, Prior: Unknown
//  Review: claude-opus-4-8, 2026-06-09 (PR #10 follow-up, issue #11) — promoted from
//  the M1K3App target into M1K3Inference so the swap logic is `swift test`-covered,
//  matching its siblings SwappableSpeechProvider/SwappableEmbeddingService. Behaviour
//  unchanged; members made `public`.
//  Review: Kev + claude-fable-5.1, 2026-09-06, Confidence 0.9 — PR #232: forwards
//  `nativePromptShape` to the active provider (the façade-forwarding rule, #133/#134).

import Foundation
import Synchronization

public final class SwappableInferenceProvider: InferenceProvider, Sendable {
    public let name = "swappable-mlx"

    private let current: Mutex<any InferenceProvider>

    public init(_ initial: any InferenceProvider) {
        current = Mutex(initial)
    }

    public var active: any InferenceProvider {
        current.withLock { $0 }
    }

    public func setProvider(_ provider: any InferenceProvider) {
        current.withLock { $0 = provider }
    }

    public var isAvailable: Bool {
        active.isAvailable
    }

    public func generate(prompt: String) async throws -> String {
        try await active.generate(prompt: prompt)
    }

    public func generateStreaming(prompt: String) -> AsyncStream<String> {
        active.generateStreaming(prompt: prompt)
    }
}

// MARK: - Native tool calling (Phase 12c)

/// Forwards the tool-calling capability to the current backing provider. Both
/// MLX slots (Lil = Qwen, Big = Gemma) conform, so when the swappable backs a
/// tool-capable model the agent gets the native loop; the runtime flag tracks
/// whichever model is currently set (a swap re-points it transparently).
extension SwappableInferenceProvider: ToolCallingProvider {
    public var supportsToolCalls: Bool {
        (active as? ToolCallingProvider)?.supportsToolCalls ?? false
    }

    /// Forwarded like every capability (the façade-forwarding rule, #133/#134).
    public var nativePromptShape: NativePromptShape {
        (active as? ToolCallingProvider)?.nativePromptShape ?? .groundingInUser
    }

    public func continueToolTurn(messages: [ToolMessage], tools: [ToolDefinition]) async throws -> ToolTurn {
        guard let toolProvider = active as? ToolCallingProvider else {
            // Defensive against the swap RACE, not against logic: `active` may
            // have been re-pointed (Settings brain switch) between LocalAgent
            // reading supportsToolCalls and this call. Throwing surfaces the
            // rare mid-turn swap; the responder's plain-RAG fallback absorbs it.
            throw InferenceError.generationFailed("active backend does not support tool calls")
        }
        return try await toolProvider.continueToolTurn(messages: messages, tools: tools)
    }

    /// Forward session creation to the ACTIVE provider so its real session
    /// (e.g. MLX's KV-cache session) is reached — falling through to the
    /// stateless default here would silently lose the per-turn cache reuse.
    public func makeToolTurnSession(
        tools: [ToolDefinition],
        options: ToolTurnOptions
    ) async throws -> any ToolTurnSession {
        guard let toolProvider = active as? ToolCallingProvider else {
            throw InferenceError.generationFailed("active backend does not support tool calls")
        }
        return try await toolProvider.makeToolTurnSession(tools: tools, options: options)
    }
}

/// Forwards the persona-carrying capability to the current backend. Without
/// this, an `as?` cast on the façade silently fails and the ReAct floor
/// re-prepends the persona a backend already carries as standing instructions
/// — the #117 duplication, back through the wrapper door (the #65
/// RecordingProvider lesson: every capability seam must be forwarded by every
/// façade, or production diverges from any eval that holds the bare provider).
/// Pinned by ReActPersonaDuplicationTests' façade cases.
extension SwappableInferenceProvider: PersonaCarrying {
    public var carriesStandingPersona: Bool {
        (active as? PersonaCarrying)?.carriesStandingPersona ?? false
    }
}

/// Forwards the tokenizer to the current backend. Same hole as above, second
/// instance: the grounding cap's `provider as? TokenCounting` cast failed on
/// the façade, so EVERY tier's cap fell back to the ~4.4 chars/token estimate
/// — the measured cap #67 shipped never measured in production. A backend
/// without a tokenizer reads nil through here, which callers already treat as
/// "estimate, never skip" (TokenCounting's own header).
extension SwappableInferenceProvider: TokenCounting {
    public func tokenCount(_ text: String) async -> Int? {
        await (active as? TokenCounting)?.tokenCount(text)
    }
}

/// Forwards the end-of-turn warm signal (the AFM prewarm re-arm) — same
/// every-façade-forwards rule as its siblings above.
extension SwappableInferenceProvider: TurnWarmable {
    public func prepareForNextTurn() {
        (active as? TurnWarmable)?.prepareForNextTurn()
    }
}

/// Forwards the raw (persona-free) completion capability — the Brain at Home
/// /v1/generate seam. Same every-façade-forwards rule as its siblings: an
/// `as?` cast that dies at the wrapper would silently make the LAN route
/// "raw unavailable" while the bare provider serves it. A backend that
/// genuinely can't do raw yields an immediately-finished stream, which the
/// listener surfaces as a 503 — never a silent persona-seeded fallback.
extension SwappableInferenceProvider: RawCompletionProviding {
    public func generateRawStreaming(prompt: String, maxTokens: Int?) -> AsyncStream<String>? {
        (active as? RawCompletionProviding)?.generateRawStreaming(prompt: prompt, maxTokens: maxTokens)
    }
}
