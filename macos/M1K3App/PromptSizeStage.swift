//
//  PromptSizeStage.swift
//  M1K3App
//
//  THE PROMPT-SIZE INSTRUMENT (M1K3_SELFTEST_PROMPTSIZE=1).
//
//  Every context guarantee in the app currently rests on an estimate nobody has
//  checked against a tokenizer. HistoryBudgetPolicy assumes 3.5 chars/token and
//  its own header names real token counting as a deferred [SPIKE];
//  DocumentChunker implies 4; AppEnvironment+ChatHistory reserves the
//  non-history prompt at 3000 tokens with grounding itemised at "~1100" — while
//  AgentRAGResponder.groundingBody interpolates retrieved chunks VERBATIM and
//  untruncated (5 doc hits × DocumentChunker.targetChars 1200, plus a second
//  memory lane). On Big the failure mode is silent: gemma-4-12B's
//  RotatingKVCache(8192) rotates the persona/grounding head out during prefill
//  and answers off-persona with no error. This stage produces the numbers that
//  turn that from an argument into a measurement.
//
//  HOW IT MEASURES — interception, not reconstruction, on BOTH paths Big can
//  take. Big always resolves NATIVE tool-calling in production (see
//  LocalAgent.run's dispatch), so its persona+tool-spec block is never a flat
//  `prompt: String` at all — LocalAgent+Native's `makeToolTurnSession` KV-seeds
//  it once per (model × tools × persona) and the agent sends only the per-turn
//  `.user` message (grounding+RULES+goal) on top of that seed. A
//  `RecordingProvider` therefore wraps the real provider at BOTH seams:
//    • the flat-prompt seam (`generate`/`generateStreaming`) for the ReAct
//      floor a model with no known tool-call dialect would fall back to;
//    • the native seam (`makeToolTurnSession`, wrapping the returned session's
//      `send`) for the path Big actually takes — capturing the exact messages
//      LocalAgent+Native sent, not a re-assembly of them.
//  The seed itself is measured via `MLXGemmaProvider.seedPrefixTokenCount`,
//  which reuses the SAME `personaPrefixSnapshot`/`prefixInputs` derivation the
//  live turn's KV-seed is built from — so it can't drift from what was
//  actually prefilled, even though (being KV-seeded, never rendered as a
//  string) it could never be recovered by splitting an intercepted prompt.
//  Re-assembling any of this from AgentRAGResponder's parts would be a second
//  implementation of prompt assembly, and the moment it drifted the instrument
//  would confidently measure something the model never saw.
//
//  The component breakdown of whatever flat text IS available (the ReAct
//  floor's whole prompt, or Big's native per-turn `.user` message) comes from
//  PromptSectionSplitter over PromptMarker.live; real token counts come from
//  the model's own tokenizer via MLXGemmaProvider.tokenCount. A tier with no
//  exposed tokenizer (AFM/mini) reports bytes with nil tokens — never a silent
//  zero.
//
//  Signed: Kev + claude-opus-4-8, 2026-07-19, Confidence 0.75 (the pure halves
//  — PromptSizeReport, PromptSectionSplitter, the marker pins — are TDD'd
//  red-first and green; this app-target glue follows ChatEvalStage's shape and
//  has no test bundle by design, so it is verify-by-launch like every other
//  SelfTest arm. The numbers it produces are the point and they are UNMEASURED
//  until Kev runs it). Prior: Unknown
//
//  Review: Kev + claude-fable-5, 2026-07-20, Confidence 0.85 — a code-review
//  bot on PR #65 caught that `RecordingProvider` conformed only to
//  `InferenceProvider`, so `LocalAgent`'s `as? ToolCallingProvider` cast
//  ALWAYS failed and every measured run silently took the ReAct floor's empty-
//  tools flat prompt — never Big's real native path, the one tier this stage
//  exists to measure. Fixed at the root: `RecordingProvider` now conforms to
//  `ToolCallingProvider` (forwarding `supportsToolCalls`/`continueToolTurn`/
//  `makeToolTurnSession` to the wrapped provider) and a `RecordingToolTurnSession`
//  wraps the real session so the exact per-turn `.user` message LocalAgent+Native
//  sends is captured at its actual call site — never reconstructed. The
//  persona+tool-spec KV-seed, which never appears as prompt text on the native
//  path, is now measured via the new `MLXGemmaProvider.seedPrefixTokenCount`
//  seam and reported as its own component. The tool palette also changed from
//  `tools: []` to `ChatEvalStage.toolPalette` — the empty list was silently
//  trimming the RULES/routing text too, on top of forcing the ReAct floor.
//  Per-turn breakdown (item 3 of the review) achieved WITHOUT touching
//  MLXToolCalling's rendering internals — `RecordingToolTurnSession` captures
//  the pure `.user` text LocalAgent+Native already assembled before it ever
//  reaches the chat-template renderer, so `PromptSectionSplitter` applies to it
//  exactly as it did to the ReAct floor's flat prompt (same "template" wrapper
//  attribution via `templatedTokenCount`). Verify-owed: an on-device run —
//  every number this stage produces is unmeasured until Kev's ⌘R (unchanged
//  from the prior signature; this review fixed WHAT gets measured, not
//  whether it has been yet).
//
//  Review: Kev + claude-fable-5, 2026-07-20 (later), Confidence 0.85 — Kev ran
//  the fixed instrument on-device (gemma-4-12B): the seed fix above works
//  (persona+tools (KV-seed) = 1380 tok showed up), but grounded-Q measured
//  BYTE-IDENTICAL to open-chat — no KNOWLEDGE block at all. Root cause: this
//  stage seeded the corpus AND ran the responder with `HashingEmbeddingService`,
//  whose embeddings aren't semantic, so retrieval cleared nothing and the
//  deliberate worst-case injection (the whole reason grounded-Q +
//  `seedWorstCaseCorpus` exist) never fired. Both call sites now use
//  `MLXEmbeddingService` (matching `ChatEvalStage.livePathObservation`'s
//  real-embedder pattern) so retrieval actually happens. Separately, folding
//  the 0-byte KV-seed/template tokens into `measuredCharsPerToken` was
//  tanking it to ~1.1 — a scary-looking artifact, not a real under-
//  reservation signal — fixed in `PromptSizeReport` (TDD'd; see that file's
//  own Review line).
//

import Foundation
import M1K3Agent
import M1K3Chat
import M1K3Eval
import M1K3Inference
import M1K3Knowledge
import M1K3MLX

/// Wraps a provider and records every prompt/turn handed to it, so the stage
/// can measure exactly what the model saw — on whichever seam the active
/// provider's turn actually took.
private actor PromptRecorder {
    private(set) var prompts: [String] = []
    /// Tools handed to `makeToolTurnSession` this run (native path only) — the
    /// exact list `seedPrefixTokenCount` must be asked about, so the measured
    /// seed matches what was actually offered, not a re-derived palette.
    private(set) var toolTurnTools: [ToolDefinition]?
    /// Every message batch sent through a native session's `send` (or the
    /// default `continueToolTurn` seam), in call order. Index 0 is always the
    /// turn's OPENING batch — `[.system(persona), .user(goal+grounding)]` —
    /// the one this stage measures; later entries (iteration ≥2, or the
    /// iteration-cap synthesis instruction) are recorded too but unused today.
    private(set) var sentMessageBatches: [[ToolMessage]] = []

    func record(_ prompt: String) {
        prompts.append(prompt)
    }

    func recordToolSession(tools: [ToolDefinition]) {
        toolTurnTools = tools
    }

    func recordSend(_ messages: [ToolMessage]) {
        sentMessageBatches.append(messages)
    }
}

private struct RecordingProvider: InferenceProvider {
    let wrapped: any InferenceProvider
    let recorder: PromptRecorder

    var name: String {
        wrapped.name
    }

    var isAvailable: Bool {
        wrapped.isAvailable
    }

    func generate(prompt: String) async throws -> String {
        await recorder.record(prompt)
        return try await wrapped.generate(prompt: prompt)
    }

    func generateStreaming(prompt: String) -> AsyncStream<String> {
        let recorder = self.recorder
        let wrapped = self.wrapped
        return AsyncStream { continuation in
            Task {
                await recorder.record(prompt)
                for await piece in wrapped.generateStreaming(prompt: prompt) {
                    continuation.yield(piece)
                }
                continuation.finish()
            }
        }
    }
}

/// The native-path half of the recorder: forwards straight to the wrapped
/// provider's own `ToolCallingProvider` conformance, so `LocalAgent`'s
/// `as? ToolCallingProvider` cast on THIS wrapper succeeds and Big's real
/// dispatch (native, not the ReAct floor) is preserved end to end.
extension RecordingProvider: ToolCallingProvider {
    var supportsToolCalls: Bool {
        (wrapped as? ToolCallingProvider)?.supportsToolCalls ?? false
    }

    func continueToolTurn(messages: [ToolMessage], tools: [ToolDefinition]) async throws -> ToolTurn {
        guard let toolProvider = wrapped as? ToolCallingProvider else {
            throw InferenceError.generationFailed(
                "RecordingProvider: wrapped provider does not conform to ToolCallingProvider"
            )
        }
        await recorder.recordSend(messages)
        return try await toolProvider.continueToolTurn(messages: messages, tools: tools)
    }

    func makeToolTurnSession(
        tools: [ToolDefinition], options: ToolTurnOptions
    ) async throws -> any ToolTurnSession {
        guard let toolProvider = wrapped as? ToolCallingProvider else {
            throw InferenceError.generationFailed(
                "RecordingProvider: wrapped provider does not conform to ToolCallingProvider"
            )
        }
        await recorder.recordToolSession(tools: tools)
        let session = try await toolProvider.makeToolTurnSession(tools: tools, options: options)
        return RecordingToolTurnSession(wrapped: session, recorder: recorder)
    }
}

/// Forwards the tokenizer seam to the wrapped provider — the #134 rule (every
/// façade forwards every capability). Without it the grounding cap's
/// `provider as? TokenCounting` cast fails on THIS wrapper, so the instrument
/// would measure grounding that was budgeted by the ~4.4 chars/token estimate,
/// not the real tokenizer — the exact eval-vs-production divergence this stage
/// exists to expose. A wrapped provider with no tokenizer reads nil through
/// here, which callers already treat as "estimate, never skip".
extension RecordingProvider: TokenCounting {
    func tokenCount(_ text: String) async -> Int? {
        await (wrapped as? TokenCounting)?.tokenCount(text)
    }
}

/// Wraps a real `ToolTurnSession` so every `send` call's messages are
/// captured at their ACTUAL call site — the exact `[ToolMessage]`
/// LocalAgent+Native assembled, before the provider ever renders them into
/// its chat template. An actor (not a class): its only state is two
/// immutable, already-Sendable references, so isolation is free and no
/// `@unchecked Sendable` escape hatch is needed.
private actor RecordingToolTurnSession: ToolTurnSession {
    private let wrapped: any ToolTurnSession
    private let recorder: PromptRecorder

    init(wrapped: any ToolTurnSession, recorder: PromptRecorder) {
        self.wrapped = wrapped
        self.recorder = recorder
    }

    func send(
        _ messages: [ToolMessage], onToken: @escaping @Sendable (String) -> Void
    ) async throws -> ToolTurn {
        await recorder.recordSend(messages)
        return try await wrapped.send(messages, onToken: onToken)
    }

    func finish() async {
        await wrapped.finish()
    }
}

enum PromptSizeStage {
    static var isRequested: Bool {
        SelfTestEnv.value("M1K3_SELFTEST_PROMPTSIZE") == "1"
    }

    /// Fixture kinds worth sizing. grounded-Q is the one that matters — it's
    /// the only kind that fills the KNOWLEDGE block — but open-chat gives the
    /// floor (persona + tools + rules with no retrieval) so the grounding cost
    /// can be read as a delta.
    private static let kinds: [TaskKind] = [.openChat, .groundedQ]

    /// Documents seeded before the sized turns, so retrieval actually fires.
    /// Chunks are deliberately built at DocumentChunker.targetChars (1200) —
    /// the WORST CASE the live path can inject, which is the number the
    /// ~1100-token reserve has to survive. MUST use the SAME real embedder the
    /// responder searches with (`MLXEmbeddingService`, not `HashingEmbeddingService`)
    /// — a hashing embedding isn't semantic, so a query/doc pair that should
    /// match under real retrieval clears nothing and the worst-case injection
    /// this whole fixture exists to exercise never lands in the prompt (found
    /// live: grounded-Q measured byte-identical to open-chat).
    private static func seedWorstCaseCorpus(into store: KnowledgeStore) async throws {
        let filler = String(repeating: "The hydraulic seal failed under load. ", count: 32)
        for index in 1 ... 6 {
            let ingester = DocumentIngester(store: store, embedder: MLXEmbeddingService())
            _ = try await ingester.ingest(
                title: "Plant Notes \(index)",
                text: "3.\(index) Seals\n\(filler.prefix(DocumentChunker.targetChars))"
            )
        }
    }

    static func run(emit: @escaping (String) -> Void) async {
        emit("• promptsize: assembling real prompts and counting real tokens…")

        let tier = BrainTier.big
        guard case let .mlx(modelID) = tier.backing else {
            emit("  – \(tier.rawValue): not an MLX tier, no tokenizer — skipped")
            return
        }
        let provider = MLXGemmaProvider(modelID: modelID)

        var measurements: [PromptSizeMeasurement] = []
        for kind in kinds {
            guard let fixture = ChatEvalFixtures.fixtures(for: kind).first else { continue }
            let recorder = PromptRecorder()
            do {
                let store = try KnowledgeStore()
                if kind == .groundedQ {
                    try await seedWorstCaseCorpus(into: store)
                }
                let responder = AgentRAGResponder(
                    store: store,
                    // Real embedder, matching the ingester above — retrieval must
                    // actually fire for grounded-Q's worst-case corpus to be found.
                    embedder: MLXEmbeddingService(),
                    provider: RecordingProvider(wrapped: provider, recorder: recorder),
                    // The REAL production palette (same one ChatEvalStage's tool-use
                    // fixtures probe) — an empty list both forced the ReAct floor
                    // (no tools to render meant nothing distinguished the two
                    // dispatch paths' RULES text) and under-measured the RULES/
                    // routing block itself, which names each offered tool.
                    tools: ChatEvalStage.toolPalette,
                    maxIterations: 1
                )
                let (_, stream) = try await responder.answerStreaming(fixture.prompt)
                for await _ in stream {}

                if let measurement = await measure(
                    kind: kind, recorder: recorder, tier: tier, provider: provider
                ) {
                    measurements.append(measurement)
                } else {
                    emit("  – \(kind.label): provider was never called — skipped")
                }
            } catch {
                emit("  – \(kind.label): failed (\(error))")
            }
        }

        emit("")
        emit(PromptSizeReport.table(measurements))
        emit("")
        emit(verdict(for: measurements))
    }

    /// Measure whichever seam the turn actually took. Big always resolves
    /// native in production, so the native branch is the one that matters —
    /// the flat-prompt branch stays as the honest fallback for a model with no
    /// resolved tool-call dialect (the ReAct floor), so this stage keeps
    /// reporting something true rather than silently going empty if a future
    /// Big model ever lost native support.
    private static func measure(
        kind: TaskKind, recorder: PromptRecorder, tier: BrainTier, provider: MLXGemmaProvider
    ) async -> PromptSizeMeasurement? {
        if let firstBatch = await recorder.sentMessageBatches.first {
            let tools = await recorder.toolTurnTools ?? []
            return await measureNative(
                messages: firstBatch, tools: tools, label: kind.label, tier: tier, provider: provider
            )
        }
        guard let prompt = await recorder.prompts.last else { return nil }
        return await measure(prompt: prompt, label: kind.label, tier: tier, provider: provider)
    }

    /// Split the intercepted flat prompt, count each section with the model's
    /// own tokenizer, and attribute the chat-template wrapper as its own
    /// component (templated whole − sum of raw sections) so the parts re-sum
    /// honestly. The ReAct-floor fallback path — see `measure(kind:...)`.
    private static func measure(
        prompt: String, label: String, tier: BrainTier, provider: MLXGemmaProvider
    ) async -> PromptSizeMeasurement {
        PromptSizeMeasurement(
            label: "\(label) [\(tier.rawValue)]",
            components: await splitAndCount(prompt, provider: provider),
            reserveTokens: AppEnvironment.historyReserveTokens,
            windowTokens: tier.approximateContextTokens
        )
    }

    /// Big's real path: the persona+tool-spec block is KV-SEEDED, never a
    /// flat prompt string, so it's measured via `seedPrefixTokenCount` (which
    /// reuses the exact seed derivation, not a reconstruction) rather than the
    /// splitter. The per-turn `.user` message — grounding+RULES+goal, exactly
    /// as `LocalAgent+Native.buildNativeGoal` assembled it — IS flat text, so
    /// it gets the SAME split-and-count recipe as the ReAct floor's prompt.
    private static func measureNative(
        messages: [ToolMessage], tools: [ToolDefinition], label: String, tier: BrainTier,
        provider: MLXGemmaProvider
    ) async -> PromptSizeMeasurement {
        var components: [PromptComponentSize] = []

        if let seedTokens = await provider.seedPrefixTokenCount(tools: tools) {
            components.append(
                PromptComponentSize(name: "persona+tools (KV-seed)", bytes: 0, tokens: seedTokens)
            )
        }
        if let userText = lastUserText(in: messages) {
            components.append(contentsOf: await splitAndCount(userText, provider: provider))
        }

        return PromptSizeMeasurement(
            label: "\(label) [\(tier.rawValue)]",
            components: components,
            reserveTokens: AppEnvironment.historyReserveTokens,
            windowTokens: tier.approximateContextTokens
        )
    }

    /// The shared recipe: `PromptSectionSplitter` over `PromptMarker.live`,
    /// each section counted with the model's own tokenizer, then the
    /// chat-template wrapper's cost attributed as its own "template" component
    /// (measured, not assumed) — used for BOTH the ReAct floor's whole flat
    /// prompt and Big's native per-turn `.user` message; only the input text
    /// differs between the two call sites.
    private static func splitAndCount(
        _ text: String, provider: MLXGemmaProvider
    ) async -> [PromptComponentSize] {
        var components: [PromptComponentSize] = []
        var sectionTokenTotal = 0
        var everySectionCounted = true

        for section in PromptSectionSplitter.split(text, markers: PromptMarker.live) {
            let tokens = await provider.tokenCount(section.text)
            if let tokens {
                sectionTokenTotal += tokens
            } else {
                everySectionCounted = false
            }
            components.append(
                PromptComponentSize(
                    name: section.name, bytes: section.text.utf8.count, tokens: tokens
                )
            )
        }

        // The wrapper's cost, measured rather than assumed.
        if everySectionCounted, let templated = await provider.templatedTokenCount(text) {
            components.append(
                PromptComponentSize(
                    name: "template", bytes: 0, tokens: max(0, templated - sectionTokenTotal)
                )
            )
        }
        return components
    }

    /// The text of the LAST `.user` message in a sent batch — for the turn's
    /// opening send (`[.system(persona), .user(goal+grounding)]`) that's the
    /// one real user turn; a later batch (a tool-result-only delta) has none,
    /// which is a legitimate absence, not a bug.
    private static func lastUserText(in messages: [ToolMessage]) -> String? {
        for message in messages.reversed() {
            if case let .user(text, _) = message { return text }
        }
        return nil
    }

    /// The headline: does the assembled prompt fit what the app reserved, and
    /// what is the real chars/token ratio the estimates should be tuned to.
    private static func verdict(for measurements: [PromptSizeMeasurement]) -> String {
        var lines = ["=== PROMPT SIZE VERDICT ==="]
        let overruns = measurements.filter { $0.exceedsReserve == true }
        if overruns.isEmpty {
            lines.append(
                "• every measured prompt fits AppEnvironment.historyReserveTokens "
                    + "(\(AppEnvironment.historyReserveTokens)tok)."
            )
        } else {
            for measurement in overruns {
                lines.append(
                    "• ⚠️ \(measurement.label) OVER reserve by "
                        + "\(measurement.reserveOverrunTokens ?? 0)tok — the replay budget is "
                        + "computed from a reserve the prompt does not honour, so history is "
                        + "over-granted and gemma's 8192 window can rotate the persona head out "
                        + "silently."
                )
            }
        }
        let ratios = measurements.compactMap(\.measuredCharsPerToken)
        if !ratios.isEmpty {
            let mean = ratios.reduce(0, +) / Double(ratios.count)
            lines.append(
                "• measured chars/token ⌀\(String(format: "%.2f", mean)) "
                    + "(HistoryBudgetPolicy assumes 3.50, DocumentChunker implies 4.00) — "
                    + "the [SPIKE] figure."
            )
        }
        return lines.joined(separator: "\n")
    }
}
