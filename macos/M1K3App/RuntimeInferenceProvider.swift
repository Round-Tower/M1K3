//
//  RuntimeInferenceProvider.swift
//  M1K3App
//
//  A façade that forwards to whichever backend the runtime picker has selected,
//  so flipping AFM ↔ MLX Gemma in Settings changes who answers the *next* turn
//  without rebuilding the RAGResponder or ChatSession (the chat transcript
//  survives the swap). The selection lives in a lock-protected box so this
//  Sendable provider can read it off the main actor at generate-time while the
//  @Observable UI mutates it on the main actor.
//
//  Generation only — the embedder is deliberately NOT switched here: it defines
//  the stored vector space, so swapping it would require a re-index.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.8, Prior: Unknown
//  Review: Kev + claude-fable-5, 2026-07-16 (concurrency deep pass) — both types
//  move from NSLock + `@unchecked Sendable` to `Mutex` + checked `Sendable`
//  (the Swappable*-family house shape): the box holds its slot in a Mutex, and
//  with that the provider's stored properties are all immutable Sendables, so
//  the compiler proves what the escape hatch used to assert.

import Foundation
import M1K3Inference
import Synchronization

/// Thread-safe holder for the picker's current selection. The @Observable
/// AppEnvironment writes it on the main actor; the façade reads it anywhere.
final class RuntimeSelectionBox: Sendable {
    private let stored: Mutex<RuntimeOption>

    init(_ initial: RuntimeOption) {
        stored = Mutex(initial)
    }

    var value: RuntimeOption {
        get { stored.withLock { $0 } }
        set { stored.withLock { $0 = newValue } }
    }
}

/// The interim-Mini bridge's routing override (InterimBrainPolicy, M1K3Inference):
/// while the selected weight-backed brain is still downloading and AFM can serve,
/// AppEnvironment sets this to `.appleFoundationModels` so turns route to Mini
/// WITHOUT touching `selectedRuntime` (whose didSet owns warm-up/cancel side
/// effects) or the persisted brain choice. nil = no override, route normally.
final class RuntimeOverrideBox: Sendable {
    private let stored = Mutex<RuntimeOption?>(nil)

    var value: RuntimeOption? {
        get { stored.withLock { $0 } }
        set { stored.withLock { $0 = newValue } }
    }
}

/// Routes each generation to the selected backend. Unknown / not-yet-wired
/// selections fall back to Apple Foundation Models.
final class RuntimeInferenceProvider: InferenceProvider, Sendable {
    let name = "runtime"

    private let selection: RuntimeSelectionBox
    private let interimOverride: RuntimeOverrideBox
    private let backends: [RuntimeOption: any InferenceProvider]
    private let fallback: any InferenceProvider

    init(
        selection: RuntimeSelectionBox,
        interimOverride: RuntimeOverrideBox,
        backends: [RuntimeOption: any InferenceProvider],
        fallback: any InferenceProvider
    ) {
        self.selection = selection
        self.interimOverride = interimOverride
        self.backends = backends
        self.fallback = fallback
    }

    private var active: any InferenceProvider {
        backends[interimOverride.value ?? selection.value] ?? fallback
    }

    var isAvailable: Bool {
        active.isAvailable
    }

    func generate(prompt: String) async throws -> String {
        try await active.generate(prompt: prompt)
    }

    func generateStreaming(prompt: String) -> AsyncStream<String> {
        active.generateStreaming(prompt: prompt)
    }
}

// MARK: - Native tool calling (Phase 12c)

/// Forwards tool-calling to the selected backend. When MLX (Lil/Big) is active
/// the agent runs the native loop; when AFM is active (no conformance until
/// Phase 12b) `supportsToolCalls` is false and the agent uses the ReAct floor.
extension RuntimeInferenceProvider: ToolCallingProvider {
    var supportsToolCalls: Bool {
        (active as? ToolCallingProvider)?.supportsToolCalls ?? false
    }

    func continueToolTurn(messages: [ToolMessage], tools: [ToolDefinition]) async throws -> ToolTurn {
        // Defensive against the swap race, not against logic: `active` may
        // have been re-pointed (Settings brain switch) between LocalAgent
        // reading supportsToolCalls and this call. Throwing surfaces the rare
        // mid-turn swap; the responder's plain-RAG fallback absorbs it.
        guard let toolProvider = active as? ToolCallingProvider else {
            throw InferenceError.generationFailed("active backend does not support tool calls")
        }
        return try await toolProvider.continueToolTurn(messages: messages, tools: tools)
    }

    /// Forward session creation to the ACTIVE provider so its real session
    /// (e.g. MLX's KV-cache session) is reached — falling through to the
    /// stateless default here would silently lose the per-turn cache reuse.
    func makeToolTurnSession(
        tools: [ToolDefinition],
        options: ToolTurnOptions
    ) async throws -> any ToolTurnSession {
        guard let toolProvider = active as? ToolCallingProvider else {
            throw InferenceError.generationFailed("active backend does not support tool calls")
        }
        return try await toolProvider.makeToolTurnSession(tools: tools, options: options)
    }
}

// MARK: - Persona carrying (the #117 dedup, through the façade)

/// Forwards the persona-carrying capability to the active backend. THIS WAS THE
/// HOLE (found 2026-08-16): the live responder holds this façade, not the bare
/// AFM provider, so `LocalAgent+ReAct`'s `as? PersonaCarrying` cast failed in
/// production and Mini was sent the persona twice — in the prompt body AND in
/// session instructions — while every eval (which constructs the bare provider)
/// showed the dedup working. Mirrors SwappableInferenceProvider's forwarding,
/// which is the package-testable twin (ReActPersonaDuplicationTests' façade
/// cases); this app-target copy is compile-checked + verify-by-launch via the
/// `afm turn: body=` log (a Mini chat turn's body should NOT carry ~3.8k
/// persona chars).
extension RuntimeInferenceProvider: PersonaCarrying {
    var carriesStandingPersona: Bool {
        (active as? PersonaCarrying)?.carriesStandingPersona ?? false
    }
}

/// Second instance of the same hole (2026-08-16): the grounding cap's
/// `provider as? TokenCounting` cast failed on this façade, so every tier's
/// cap estimated (~4.4 chars/token) instead of measuring with the real MLX
/// tokenizer. nil through here still means "estimate, never skip".
extension RuntimeInferenceProvider: TokenCounting {
    func tokenCount(_ text: String) async -> Int? {
        await (active as? TokenCounting)?.tokenCount(text)
    }
}

/// Forwards the end-of-turn warm signal (the AFM prewarm re-arm) — same
/// every-façade-forwards rule as its siblings above.
extension RuntimeInferenceProvider: TurnWarmable {
    func prepareForNextTurn() {
        (active as? TurnWarmable)?.prepareForNextTurn()
    }
}
