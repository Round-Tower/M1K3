//
//  MLXGemmaProvider.swift
//  M1K3MLX
//
//  Gemma generation on-device via MLX (Metal), behind the same InferenceProvider
//  seam as AppleFoundationModelsProvider. This is M1K3's "main brain" tier — when
//  selected, the chat answers stream from a real Gemma running in-process, no
//  server, no cloud.
//
//  Unproven-path note: the broader prior-project stack only ever exercised
//  MLXEmbedders; MLXLLM generation is new here. It's compile-verified and covered
//  by a gated integration test (downloads weights — minutes, network), but the
//  first real on-device generation is the milestone to watch, not a settled fact.
//
//  Default model: gemma-3-1b-it (QAT 4-bit, ~1GB) — the smallest current Gemma,
//  picked so the first download is tolerable. Pass a beefier ModelConfiguration
//  (e.g. LLMRegistry.gemma_2_9b_it_4bit) for quality once the path is trusted.
//
//  Streaming contract: MLX yields *delta* chunks (incremental text). ChatSession's
//  fold normalises that against AFM's cumulative snapshots, so both render right.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.65, Prior: Unknown
//  Context: First MLXLLM generation in the M1K3 / prior-project family — the PLAN's
//  flagged Phase-2 risk ("confirm MLXLLM runs Gemma cleanly"). Compiles; runtime
//  generation pending on-device verification.
//
//  Review: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.8 — added
//  `ModelPreloading` conformance + `prepare(progress:)` and threaded
//  `loadContainer`'s `progressHandler` through `ensureLoaded`, so the ~1GB first
//  download reports a 0...1 fraction to the UI instead of stalling silently. The
//  progress path is still verify-by-launch (MLX only runs from the .app).
//
//  Review: Kev + claude-opus-4-8, 2026-06-08, Confidence 0.85 - replaced the
//  check-then-act NSLock cache with a SingleFlightLoader actor. The old
//  ensureLoaded read the cache under the lock, RELEASED it, then ran the slow
//  load unlocked, so a Settings preload racing the first generate could both pass
//  the nil-check and download the container twice. The loader coalesces them into
//  one load (proven Metal-free in SingleFlightLoaderTests).
//  Review: Kev + claude-fable-5, 2026-06-12, Confidence 0.8 — repetitionPenalty
//  1.1 / repetitionContextSize 64 as the degenerate-loop guard (values pinned
//  in tests; effect on think-phase + FACT-line distillation is verify-at-⌘R).
//  Review: Kev + claude-fable-5, 2026-07-15, Confidence 0.9 — Ternary-Bonsai-8B
//  joins the quantized-KV allow-list by exact size id (dense Qwen3 under the
//  brand: Qwen3Model → attentionWithCacheUpdate, verified vs the HF config).
//  The unverified Qwen3.6-based 27B keeps the crash-safe default, test-pinned.
//  Review: Kev + claude-fable-5, 2026-07-16, Confidence 0.9 — the 2507 line
//  EXCLUDED from the thinking toggle: Qwen split the refresh into fixed-mode
//  variants and dropped enable_thinking from both templates (verified vs HF);
//  the Instruct variant is the wired lil, so an over-claimed toggle would ship
//  a dead reasoning picker. Stock qwen3 keeps the toggle, test-pinned both ways.
//  Review: Kev + claude-fable-5, 2026-07-16 (evening), Confidence 0.85 — the
//  torn-cache pre-load tripwire (ModelCacheIntegrity.healBeforeLoad) inside
//  the retry operation: a partial model dir crashed the process in mlx-swift's
//  quantize (swift_unexpectedError; stack-evidenced). Directory via HubApi's
//  own localRepoLocation (the LocalModelInventory never-drift rule); resumable
//  .incomplete downloads are protected from the heal (review catch).
//  Review: Kev + claude-fable-5, 2026-08-15 — releaseModel() added (full
//  unload incl. the container via SingleFlightLoader.reset) for the escalated
//  deep dive's parked-brain memory story (PR #130). Idle-only by doc contract.
//  Confidence 0.85 — Metal half is verify-by-launch per the metallib wall.

import Foundation
import Hub
import M1K3Inference
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM
import os

/// Model-load diagnostics. File-scope so the load closure (which runs off the
/// provider's isolation) can log retries without capturing `self`.
private let mlxLoadLog = Logger(subsystem: "app.m1k3", category: "mlx-load")

/// Per-generation latency diagnostics: prompt size, prefill time (the real
/// time-to-first-token driver), and decode throughput. Stream with:
///   log stream --predicate 'subsystem == "app.m1k3" AND category == "ttft"'
/// Internal (unlike mlxLoadLog above) BY DESIGN — shared with
/// MLXToolCalling.swift and the prompt-cache persistence extension.
let mlxTTFTLog = Logger(subsystem: "app.m1k3", category: "ttft")

/// Log one generation's completion metrics. Free function taking only params
/// (the swiftformat↔Logger autoclosure landmine: never interpolate members).
/// Internal by design — called from MLXToolCalling.swift too.
func logGenerationInfo(
    _ info: GenerateCompletionInfo, label: String, model: String,
    totalContextTokens: Int? = nil
) {
    let promptTokens = info.promptTokenCount
    let prefillMS = Int(info.promptTime * 1000)
    let decodeTokens = info.generationTokenCount
    let tokensPerSecond = Int(info.tokensPerSecond)
    // model id included so timings stay attributable after a mid-session brain swap.
    mlxTTFTLog.notice(
        "\(label, privacy: .public) [\(model, privacy: .public)]: prompt=\(promptTokens)tok prefill=\(prefillMS)ms decode=\(decodeTokens)tok @\(tokensPerSecond)tok/s"
    )
    // The user-facing readout wants TRUE context (window pressure), not this
    // call's prefill: with the persona-prefix KV cache warm, promptTokenCount
    // is only the suffix past the cache — a fully-grounded turn read "2%" while
    // actually carrying ~1.3K cached persona tokens. Callers that know the full
    // rendered length pass it; the log line above stays per-call (prefill cost).
    GenerationMetricsReporter.report(GenerationMetrics(
        promptTokens: totalContextTokens ?? promptTokens,
        generationTokens: decodeTokens,
        tokensPerSecond: info.tokensPerSecond
    ))
}

/// `@unchecked Sendable`: model loading is coalesced through a `SingleFlightLoader`
/// actor and the loaded `ModelContainer` is itself an isolation actor; everything
/// else is immutable.
public final class MLXGemmaProvider: InferenceProvider, ModelPreloading, @unchecked Sendable {
    public let name: String

    let generateParameters: GenerateParameters
    private let loader: SingleFlightLoader<ModelContainer>
    /// The native tool-call dialect for this model, resolved at init from the
    /// model family (Gemma → .gemma, Qwen/Llama → .json, …). nil means "no known
    /// dialect" → `supportsToolCalls` is false and the agent uses the ReAct floor.
    let resolvedToolCallFormat: ToolCallFormat?
    /// Whether output needs a synthetic `<think>` opener: the model's chat
    /// template PRE-OPENS `<think>` in the generation prompt (Qwen3.5), so the
    /// model emits only the CLOSING tag — prepending the opener keeps the
    /// downstream reasoning split seeing a well-formed pair. Effective flag:
    /// family AND `thinkingEnabled` (a disabled-thinking prompt emits no tags).
    let thinkPrefixNeeded: Bool
    /// Reasoning on/off for models whose template supports `enable_thinking`
    /// (Qwen3.5). Default on — M1K3 surfaces reasoning, it doesn't hide it.
    /// `false` renders the empty think pair into the prompt (the model skips
    /// straight to the answer — a large TTFT lever for a future fast-mode
    /// toggle) and disables the synthetic prefix.
    let thinkingEnabled: Bool
    /// Whether the family's template understands `enable_thinking` at all.
    /// (Internal: the tool-calling extension reads it for per-turn fast mode.)
    let supportsThinkingToggle: Bool
    /// Whether the template pre-opens a `<think>` tag (Qwen3.5 only) — distinct
    /// from toggle support. Read by the tool path to decide the synthetic opener.
    let preOpensThinkTemplate: Bool
    /// The model id this provider was built for — keys the persona prefix.
    /// Public so the app can skip a redundant `selectBrain` reload when the active
    /// provider already serves this model.
    public let modelIdentifier: String
    /// Per-(tools × persona) prefilled system-block KV prefix; turns start
    /// from copies instead of re-prefilling the persona every time.
    let personaPrefix = PersonaPrefixCache()
    /// The last turn's end-of-turn KV cache — the cross-TURN seed, so a
    /// continuing conversation reuses past the persona instead of
    /// re-prefilling its own history every turn. See ConversationTailCache.
    let conversationTail = ConversationTailCache()
    /// Coalesces concurrent builds of the SAME prefix. Measured 2026-08-09:
    /// without it, several callers miss the cache together, serialise on the
    /// ModelContainer, and each pays a full ~13s prefill for a prefix the
    /// first one was already building. A bigger cache cannot fix that — every
    /// entrant missed before the first store existed.
    private let prefixBuilds = SingleFlight<PersonaCacheKey, Bool>()

    /// The default generation ceiling, NOT a target — the model stops at EOS
    /// naturally, so this is free for short replies. Reasoning models (Qwen3)
    /// spend hundreds of tokens in <think> before the tool call / answer; the
    /// old 512 cap cut them off mid-thought. 4096 leaves room to think, act,
    /// AND answer across an agent iteration. ⚠️ `HistoryBudgetPolicy.
    /// generationTokenCap`'s `defaultCap` mirrors this figure across the
    /// Chat↔MLX module boundary — an equality test pins them together (116-F1).
    public static let defaultMaxTokens = 4096

    public init(
        configuration: ModelConfiguration = LLMRegistry.gemma3_1B_qat_4bit,
        maxTokens: Int = MLXGemmaProvider.defaultMaxTokens,
        name: String = "mlx-gemma",
        thinkingEnabled: Bool = true
    ) {
        var params = GenerateParameters()
        params.maxTokens = maxTokens
        // Degenerate-loop guard: penalise tokens repeated within the recent
        // window so a confabulating small model can't lock into a verbatim
        // loop. 1.1 is the widely-used mild setting; heavier (≥1.2) measurably
        // distorts tool-call JSON and citation tokens. 64 tokens of context
        // (default is 20) reaches sentence-length loops; true mid-generation
        // loop DETECTION is deferred until per-token cancellation exists —
        // without it a detector could watch a loop but not stop it.
        params.repetitionPenalty = 1.1
        params.repetitionContextSize = 64
        if Self.supportsQuantizedKVCache(for: configuration) {
            // 8-bit quantized KV: halves per-token KV memory and, since decode is
            // memory-bandwidth-bound, speeds long transcripts. Replaces the
            // maxKVSize rotation backstop for these families — maxKVSize must stay
            // nil because upstream quantizes only KVCacheSimple (RotatingKVCache.
            // toQuantized() is an unimplemented fatalError), so setting both
            // silently disables kvBits. The rotation cap was sized to never fire
            // (and would rotate the prompt out — a silent quality cliff — if it
            // did); growth stays bounded in practice by the per-turn session
            // lifecycle + maxTokens.
            params.kvBits = 8
            params.kvGroupSize = 64
            params.quantizedKVStart = 0
        } else if Self.supportsCallerKVCapacity(for: configuration) {
            // Hard-bound KV-cache growth (the cache rotates past this) so a long
            // agent transcript can't balloon memory without limit. The 4096
            // maxTokens above is only this class's DEFAULT: the live app caps a
            // rotating-KV tier (gemma/big) at HistoryBudgetPolicy.
            // rotatingGenerationTokenCap (2048) so prefill + decode fit 8192
            // together — an uncapped 4096 decode can cross the window mid-answer
            // and silently rotate the persona/grounding head out.
            //
            // ALLOW-LISTED families only (today: llama alone). Most
            // architectures own their cache geometry and ignore a requested
            // capacity — see supportsCallerKVCapacity for the list and why the
            // default is "no capacity".
            params.maxKVSize = 8192

            // PREFILL CHUNKING — measured 2026-08-09 on this machine (M1 Max,
            // powermode 0), same 2357-token prompt every run:
            //
            //   upstream default   14333 / 14254 ms   (two runs, <0.6% apart)
            //   stepSize 1024      13092 ms           -8.5%
            //   stepSize 2048      13074 ms           -8.5%  (clamps to 1024)
            //   unchunked          14513 ms           +1.5%  — bigger is NOT better
            //
            // 1024 and 2048 land together because upstream clamps the step to the
            // model's `maximumStepSize`, which for gemma-4 is its sliding window.
            // So this is really "use the whole window per forward"; the gemma text
            // path's own default is smaller and costs us ~8.5% on every turn.
            //
            // Why this matters more than it looks: gemma-4's 1024-token window
            // means the KV cache WRAPS on every real turn (prompts run 2.3-2.9k),
            // which vetoes cross-turn reuse entirely — see MLXToolCalling's
            // `reusable` gate. Every turn re-prefills the whole prompt, so prefill
            // THROUGHPUT is the only lever left short of changing brains.
            //
            // Scoped to the family it was measured on. Qwen (Lil) has no sliding
            // window and reuse works there, so its prefill profile is a different
            // question and gets upstream's default until someone measures it.
            if Self.prefersWindowSizedPrefill(for: configuration) {
                params.prefill.stepSize = 1024
            }
            // Escape hatch for the next measurement pass — one build, many variants:
            //   defaults write app.m1k3 prefillStepSize -int 2048
            let stepOverride = UserDefaults.standard.integer(forKey: "prefillStepSize")
            if stepOverride > 0 { params.prefill.stepSize = stepOverride }
        }
        generateParameters = params
        self.name = name

        // Resolve the model's native tool-call dialect and bake it into the
        // configuration. `ToolCallFormat.infer` matches model_type == "gemma"
        // EXACTLY, so Gemma-3/3n (and Qwen) would silently fall back to .json
        // and never parse — we set the format explicitly per model family.
        let resolved = Self.resolveToolCallFormat(for: configuration)
        resolvedToolCallFormat = resolved
        self.thinkingEnabled = thinkingEnabled
        modelIdentifier = configuration.name
        let familyPreOpens = Self.templatePreOpensThink(for: configuration)
        preOpensThinkTemplate = familyPreOpens
        // Toggle support is the WHOLE Qwen3 family — NOT tied to the 3.5-only
        // pre-open check (the conflation that disabled fast mode after #94).
        supportsThinkingToggle = Self.templateSupportsThinkingToggle(for: configuration)
        thinkPrefixNeeded = thinkingEnabled && familyPreOpens
        let loadConfiguration: ModelConfiguration = {
            var config = configuration
            if let resolved { config.toolCallFormat = resolved }
            return config
        }()

        // Single-flight the container load so a Settings preload racing the first
        // generate share ONE ~1GB download instead of each kicking off their own.
        // Retry on transient network failures: a HuggingFace CDN timeout would
        // otherwise kill the turn, but the download is resumable so each retry
        // continues the cached partial rather than restarting.
        loader = SingleFlightLoader { progress in
            try await withRetry(
                onRetry: { attempt, error in
                    let reason = error.localizedDescription
                    mlxLoadLog.notice(
                        "model load attempt \(attempt) failed (\(reason, privacy: .public)); retrying"
                    )
                },
                operation: {
                    // Pre-load tripwire (2026-07-16): a torn cache dir (index
                    // promising shards the disk doesn't back) reaches mlx-swift's
                    // quantize pass and dies as swift_unexpectedError — a process
                    // death, not a thrown load failure. Heal (delete → HubApi
                    // re-downloads) BEFORE the loader can read it; inside the
                    // retry so a failed attempt re-checks. Directory via HubApi's
                    // OWN path resolution (the LocalModelInventory rule: detection
                    // and download must never drift).
                    ModelCacheIntegrity.healBeforeLoad(
                        directory: HubApiDownloader.llmDefault.hub
                            .localRepoLocation(Hub.Repo(id: loadConfiguration.name))
                    )
                    // Route to the factory this checkpoint is proven on. Both
                    // produce the SAME ModelContainer type, so everything
                    // downstream (persona prefix, tool sessions, generate) is
                    // factory-agnostic; the VLM path additionally keeps the
                    // vision tower resident (image input + future MTP drafter).
                    if Self.usesVLMLoadPath(for: loadConfiguration) {
                        return try await VLMModelFactory.shared.loadContainer(
                            from: HubApiDownloader.llmDefault,
                            using: TransformersTokenizerLoader(),
                            configuration: loadConfiguration
                        ) { prog in
                            progress(prog.fractionCompleted)
                        }
                    }
                    return try await LLMModelFactory.shared.loadContainer(
                        from: HubApiDownloader.llmDefault,
                        using: TransformersTokenizerLoader(),
                        configuration: loadConfiguration
                    ) { prog in
                        progress(prog.fractionCompleted)
                    }
                }
            )
        }
    }

    /// Convenience: point at any HuggingFace model id (e.g. a locally-cached
    /// model) without the caller importing MLXLLM's ModelConfiguration.
    /// Uses the upstream registry entry when one exists — that carries model
    /// metadata a bare id misses (Gemma 4 needs extraEOSTokens ["<turn|>"]);
    /// unknown ids fall back to a plain configuration.
    public convenience init(
        modelID: String,
        maxTokens: Int = MLXGemmaProvider.defaultMaxTokens,
        name: String = "mlx-gemma",
        thinkingEnabled: Bool = true
    ) {
        self.init(
            configuration: LLMRegistry.shared.configuration(id: modelID),
            maxTokens: maxTokens,
            name: name,
            thinkingEnabled: thinkingEnabled
        )
    }

    /// True on this target by construction: macOS 26 / Apple Silicon always has
    /// the Metal GPU MLX needs. The model itself downloads lazily on first use,
    /// so availability here means "this backend can serve", not "weights present".
    public var isAvailable: Bool {
        true
    }

    /// Warm the model ahead of the first turn, reporting download progress, so
    /// the runtime picker can show a real bar instead of a silent ~1GB stall.
    /// No-ops fast once the container is cached.
    public func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await ensureLoaded(progress: progress)
    }

    /// Fully unload this provider: everything `releaseMemory()` frees PLUS the
    /// model container itself (weights). `releaseMemory()` alone cannot shrink
    /// a parked provider below its weight footprint — the SingleFlightLoader
    /// caches the container for the object's lifetime — which is exactly wrong
    /// for the escalated deep dive, where the parked front brain must not sit
    /// beside Big against the process-global back-pressure ceiling (#130
    /// review catch). The provider stays fully usable: the next generate's
    /// `ensureLoaded` re-runs the loader and reloads from disk.
    ///
    /// Only for a provider that is IDLE — evicting under an in-flight
    /// generation would not crash (ARC keeps the container alive through the
    /// generation) but the memory would not actually return until it finishes.
    public func releaseModel() async {
        await loader.reset()
        personaPrefix.invalidate()
        conversationTail.invalidate()
        MLXMemoryBudget.reclaim(label: "releaseModel")
    }

    /// Eagerly release cached Metal state (persona KV prefix) and return
    /// freed buffers to the OS. Call before dropping a provider (brain swap)
    /// so its Metal allocations don't linger in the freed-buffer pool.
    /// Safe to call while a generation is in flight — `PersonaPrefixCache`
    /// holds a lock during snapshot copy, and ARC keeps the copied KV arrays
    /// alive through the generation independent of this invalidation.
    public func releaseMemory() {
        personaPrefix.invalidate()
        conversationTail.invalidate()
        MLXMemoryBudget.reclaim(label: "releaseMemory")
    }

    public func generate(prompt: String) async throws -> String {
        let container = try await ensureLoaded()
        // Return cached Metal buffers after every generation — without this the
        // process-global MLX cache holds each generation's peak forever.
        defer { MLXMemoryBudget.reclaim(label: "generate") }
        let (session, seedTokens) = await makeUpstreamSession(container)
        var raw = ""
        for try await event in session.streamDetails(to: prompt, images: [], videos: []) {
            if let piece = event.chunk { raw += piece }
            if let info = event.info {
                logGenerationInfo(
                    info, label: "generate", model: modelIdentifier,
                    totalContextTokens: seedTokens + info.promptTokenCount
                )
            }
        }
        return Self.normaliseThinkPrefix(raw, preOpened: thinkPrefixNeeded)
    }

    public func generateStreaming(prompt: String) -> AsyncStream<String> {
        AsyncStream { continuation in
            let task = Task {
                // Runs on every exit — completion, error, and cancellation via
                // onTermination (cancel makes the stream loop throw into catch).
                defer { MLXMemoryBudget.reclaim(label: "generateStreaming") }
                do {
                    let container = try await ensureLoaded()
                    let (session, seedTokens) = await makeUpstreamSession(container)
                    // Qwen3.5's template pre-opens <think>, so the stream's
                    // first real token is already chain-of-thought — surface
                    // the opener so live reasoning splitting engages from
                    // token one instead of after the closing tag.
                    if thinkPrefixNeeded { continuation.yield("<think>") }
                    for try await event in session.streamDetails(to: prompt, images: [], videos: []) {
                        if let chunk = event.chunk { continuation.yield(chunk) }
                        if let info = event.info {
                            logGenerationInfo(
                                info, label: "stream", model: modelIdentifier,
                                totalContextTokens: seedTokens + info.promptTokenCount
                            )
                        }
                    }
                    continuation.finish()
                } catch {
                    // Per the InferenceProvider contract, errors terminate the
                    // stream rather than throwing. A user "stop" cancels the task
                    // (see onTermination) and lands here as CancellationError —
                    // that's normal, so only a genuine failure is worth an error
                    // line (else every stop emits a false error).
                    if !(error is CancellationError) {
                        // ttft, not mlx-load: this is a RUNTIME generation
                        // failure — filtering the load/swap category shouldn't
                        // surface it, and generation telemetry should.
                        mlxTTFTLog.error("""
                        generateStreaming failed [\(self.modelIdentifier, privacy: .public)]: \
                        \(error.localizedDescription, privacy: .public)
                        """)
                    }
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func ensureLoaded(
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> ModelContainer {
        // Bound the process-global Metal cache BEFORE any MLX work can run.
        MLXMemoryBudget.applyOnce()
        return try await loader.value(progress: progress)
    }

    /// One-shot upstream session for the plain-chat paths: seeded from the
    /// persona prefix cache when available (instructions stay nil — the cache
    /// IS the system turn), falling back to plain instructions. Thinking
    /// toggle rendered when the family supports it.
    /// Also returns how many tokens the seeded persona prefix already holds, so
    /// callers can report TRUE context (seed + this call's prefill) rather than
    /// the suffix-only count the completion info carries. 0 when unseeded (the
    /// persona rides inline and is counted by the prefill itself).
    private func makeUpstreamSession(
        _ container: ModelContainer
    ) async -> (session: ChatSession, seedTokens: Int) {
        let session: ChatSession
        let seedTokens: Int
        if let seed = await personaPrefixSnapshot(container: container, specs: nil, toolNames: []) {
            session = ChatSession(
                container,
                cache: seed.cache,
                generateParameters: generateParameters
            )
            seedTokens = seed.tokenIDs.count
        } else {
            session = ChatSession(
                container,
                instructions: M1K3Persona.systemPrompt,
                generateParameters: generateParameters
            )
            seedTokens = 0
        }
        if let context = thinkingAdditionalContext {
            session.additionalContext = context
        }
        return (session, seedTokens)
    }

    /// Get-or-build the persona prefix for this model + tool set. Best-effort:
    /// any failure (no template tokenizer, render error) returns nil and the
    /// caller falls back to sending the system turn as a normal message.
    func personaPrefixSnapshot(
        container: ModelContainer,
        specs: [ToolSpec]?,
        toolNames: [String],
        key: PersonaCacheKey? = nil
    ) async -> PersonaPrefixSnapshot? {
        do {
            return try await buildPersonaPrefixSnapshot(
                container: container, specs: specs, toolNames: toolNames, key: key
            )
        } catch {
            let reason = String(describing: error)
            mlxLoadLog.notice("persona prefix unavailable — sending system turn inline (\(reason, privacy: .public))")
            return nil
        }
    }

    /// THE key for this provider's cached prefixes — persona AND conversation
    /// tail share it (one derivation, so the tail can never seed a turn whose
    /// persona/tools render differs from what its arrays hold).
    func toolTurnCacheKey(toolNames: [String]) -> PersonaCacheKey {
        PersonaCacheKey(
            modelID: modelIdentifier,
            toolNames: toolNames,
            // Exemplars ride the CACHED render — they cost once per launch,
            // not per turn. The fallback (inline instructions) stays compact.
            personaText: M1K3Persona.systemPrompt(includeExemplars: true)
        )
    }

    /// The throwing core of the prefix build — the kv-persist probe calls this
    /// directly so failures surface with their REAL error, not the app path's
    /// swallowed best-effort nil.
    ///
    /// `key` skips a redundant re-derivation when the caller already computed
    /// it (makeToolTurnSession derives it to probe the conversation tail);
    /// nil derives it here — the two paths cannot disagree, it's one function.
    func buildPersonaPrefixSnapshot(
        container: ModelContainer,
        specs: [ToolSpec]?,
        toolNames: [String],
        key precomputed: PersonaCacheKey? = nil
    ) async throws -> PersonaPrefixSnapshot? {
        let key = precomputed ?? toolTurnCacheKey(toolNames: toolNames)
        if let hit = personaPrefix.snapshot(for: key) { return hit }
        // Background housekeeping (titles, follow-ups, distillation) may USE a
        // cached prefix but must never BUILD one: on 2026-08-09 a 64-token
        // title rendered its own prefix, took the only slot, and cost the next
        // interactive turn 16-19s of re-prefill. The cache is two slots now, so
        // this is the belt to that pair of braces — capacity holds only while
        // prefixes outnumber slots, and the key includes the TOOL SET, so that
        // count is not fixed at two. Sending the persona inline costs this one
        // small call a little; taking the slot cost the next real turn a lot.
        if InferenceIntent.isBackgroundUtility { return nil }
        // Single-flight the BUILD, then let every caller take its OWN snapshot.
        //
        // Coalescing the RESULT would be a correctness bug, not just a shortcut:
        // a snapshot hands over live KVCache arrays that the caller's decode
        // mutates, so concurrent turns sharing one snapshot would corrupt each
        // other. `snapshot(for:)` deep-copies per caller — that has to stay
        // per caller. What is wasteful to repeat is the 13-second PREFILL, and
        // that is what this deduplicates.
        _ = try await prefixBuilds.run(key) { [self] in
            // A build that finished while we queued makes this free. `contains`,
            // not `snapshot`: this only needs to know whether one landed, and a
            // snapshot here would deep-copy a ~2k-token prefix to discard it.
            if personaPrefix.contains(key) { return true }
            try await renderPersonaPrefix(container: container, specs: specs, key: key)
            return true
        }
        return personaPrefix.snapshot(for: key)
    }

    /// The actual prefill: renders the system block, prefills it, and STORES it.
    /// Only ever entered once per key at a time (see the coalescer above).
    private func renderPersonaPrefix(
        container: ModelContainer,
        specs: [ToolSpec]?,
        key: PersonaCacheKey
    ) async throws {
        let persona = key.personaText

        let parameters = generateParameters
        // `@unchecked Sendable` box: the cache arrays are evaluated by the
        // prefill generation before crossing isolation (the same contract
        // MLXToolTurnSession relies on for its per-turn cache).
        struct PrefixBox: @unchecked Sendable {
            let cache: [KVCache]
            let tokenIDs: [Int]
        }
        // Resolved OUTSIDE the closure: touching `self.configuration` inside it
        // makes the closure async and `perform`'s overload no longer matches.
        let reusableWindow = Self.slidingWindow(forModelID: modelIdentifier)
        let built: PrefixBox = try await container.perform { context in
            // System-block token ids, no assistant opener. Lenient templates
            // render a system-only array; strict ones (Qwen3.5) reject it and
            // need the two-probe boundary slice — see systemBlockIDs.
            let ids = try self.systemBlockIDs(context: context, persona: persona, specs: specs)
            // Tokenising is cheap; the prefill is not. If the prefix cannot
            // survive this model's sliding window, stop HERE — building it
            // burns seconds of GPU for a cache the cross-turn gate will veto
            // on every single turn.
            // An EMPTY box is the "declined" signal — keeping the closure's
            // return type unchanged keeps `perform`'s overload resolution happy.
            guard reusableWindow.map({ ids.count <= $0 }) ?? true else {
                return PrefixBox(cache: [], tokenIDs: [])
            }
            // Prefill: run a 1-token generation over the prefix, then trim
            // the cache back to exactly the prompt (the sampled token must
            // not pollute the reusable prefix).
            var prefill = parameters
            prefill.maxTokens = 1
            let cache = context.model.newCache(parameters: parameters)
            let stream = try MLXLMCommon.generate(
                input: LMInput(tokens: MLXArray(ids)),
                cache: cache,
                parameters: prefill,
                context: context
            )
            for await _ in stream {}
            // Trim the sampled token back off — but only on a linear cache. If a
            // long persona overran a sliding window the cache wrapped, and
            // trimming a wrapped RotatingKVCache underflows its rotation pointer
            // (the temporalOrder crash). A wrapped prefix can't be linearly
            // reused anyway; leave it untrimmed — the cross-turn gate rejects a
            // non-trimmable seed downstream, so it just re-prefills, never reuses.
            if CrossTurnCacheReuse.cacheReusable(layersTrimmable: cache.map(\.isTrimmable)) {
                for layer in cache {
                    let extra = layer.offset - ids.count
                    if extra > 0 { _ = layer.trim(extra) }
                }
            }
            return PrefixBox(cache: cache, tokenIDs: ids)
        }
        guard !built.tokenIDs.isEmpty else {
            mlxTTFTLog.notice(
                "persona prefix SKIPPED — longer than the sliding window, so no turn could reuse it"
            )
            return
        }
        personaPrefix.store(built.cache, tokenIDs: built.tokenIDs, for: key)
        let tokens = built.tokenIDs.count
        // Key fingerprint stays in the line: this log is the ONLY way to tell a
        // legitimate second prefix (a different tool palette) from the same one
        // being rebuilt — the distinction that separated a cache-capacity bug
        // from a cache STAMPEDE on 2026-08-09, and they want opposite fixes.
        mlxTTFTLog.notice(
            "persona prefix built: \(tokens)tok key=\(key.hashValue, privacy: .public) tools=[\(key.toolsFingerprint, privacy: .public)]"
        )
    }

    /// System-block token ids for the persona prefill (no assistant opener).
    ///
    /// Lenient templates (gemma) render a system-only message array directly.
    /// Strict ones (Qwen3.5) raise "No user query found in messages" on a
    /// system-only array — so on that throw we bracket the system block behind
    /// two throwaway user turns whose first content token differs, and slice at
    /// the boundary the subtraction locates (SystemBlockBoundary). The shared
    /// user header cancels in the subtraction, so even a leading-space
    /// tokenisation artifact is harmless. An unresolvable boundary re-throws the
    /// original error → the caller sends the system turn inline (correct, just
    /// unoptimised). A wrong boundary is never returned.
    func systemBlockIDs(
        context: ModelContext,
        persona: String,
        specs: [ToolSpec]?
    ) throws -> [Int] {
        guard let upstream = (context.tokenizer as? TransformersTokenizerAdapter)?.upstream else {
            throw InferenceError.generationFailed("no template tokenizer for persona prefix")
        }
        func render(_ messages: [[String: String]], tools: [ToolSpec]?) throws -> [Int] {
            try upstream.applyChatTemplate(
                messages: messages,
                chatTemplate: nil,
                addGenerationPrompt: false,
                truncation: false,
                maxLength: nil,
                tools: tools
            )
        }
        let system: [String: String] = ["role": "system", "content": persona]
        do {
            return try render([system], tools: specs)
        } catch {
            let userA: [String: String] = ["role": "user", "content": "x"]
            let userB: [String: String] = ["role": "user", "content": "7"]
            // Probes carry the SAME tools (R) / none (U) as the persona render,
            // so the user-header length the subtraction removes is exact.
            let renderA = try render([system, userA], tools: specs)
            let renderB = try render([system, userB], tools: specs)
            let userOnlyA = try render([userA], tools: nil)
            let userOnlyB = try render([userB], tools: nil)
            guard let length = SystemBlockBoundary.systemBlockLength(
                renderA: renderA,
                renderB: renderB,
                userOnlyA: userOnlyA,
                userOnlyB: userOnlyB
            ) else {
                mlxLoadLog.notice("persona prefix: system-block boundary unresolved — inline system turn")
                throw error
            }
            return Array(renderA.prefix(length))
        }
    }

    /// Template context for the `enable_thinking` switch. nil when thinking is
    /// on (the template's default) or the family has no such switch.
    var thinkingAdditionalContext: [String: any Sendable]? {
        guard supportsThinkingToggle, !thinkingEnabled else { return nil }
        return ["enable_thinking": false]
    }

    /// Self-test diagnostics: how the chat template renders for `prompt` on
    /// this model — token count, the rendered text, and EOS metadata. Used by
    /// the headless self-test to debug template/tokenizer regressions; not a
    /// production code path.
    public func templateDebugDescription(prompt: String) async -> String {
        do {
            let container = try await ensureLoaded()
            return try await container.perform { context in
                let noTools: [[String: any Sendable]]? = nil
                let noContext: [String: any Sendable]? = nil
                let ids = try context.tokenizer.applyChatTemplate(
                    messages: [["role": "user", "content": prompt]],
                    tools: noTools,
                    additionalContext: noContext
                )
                let rendered = context.tokenizer.decode(tokenIds: ids, skipSpecialTokens: false)
                let eos = context.tokenizer.eosToken ?? "nil"
                return "ids=\(ids.count) eos=\(eos) rendered=[\(rendered.suffix(160))]"
            }
        } catch {
            return "template debug failed: \(error)"
        }
    }

    /// REAL token count for `text` through this model's own tokenizer — the
    /// ground truth the prompt-size instrument exists to produce, replacing the
    /// char≈token estimates that every context guarantee currently rests on
    /// (HistoryBudgetPolicy assumes 3.5 chars/token and names real counting as
    /// a deferred [SPIKE]; DocumentChunker implies 4).
    ///
    /// Deliberately RAW `encode` — no chat template. Two reasons: the caller
    /// measures prompt SECTIONS, and per-section template overhead would be
    /// counted once per section, inflating the total and breaking the
    /// "components re-sum to the whole" invariant; and the wrapper's cost is
    /// itself measurable as (templated whole − sum of raw sections).
    ///
    /// nil (never 0) when the model can't be loaded — a confident zero would
    /// read as "measured, and free".
    public func tokenCount(_ text: String) async -> Int? {
        do {
            let container = try await ensureLoaded()
            return await container.perform { context in
                context.tokenizer.encode(text: text).count
            }
        } catch {
            return nil
        }
    }

    /// Token count for `text` WITH the chat template applied — the true cost of
    /// a fully-assembled prompt, wrapper included. Pair with `tokenCount` to
    /// attribute the difference to template overhead.
    public func templatedTokenCount(_ text: String) async -> Int? {
        do {
            let container = try await ensureLoaded()
            return try await container.perform { context in
                let noTools: [[String: any Sendable]]? = nil
                let noContext: [String: any Sendable]? = nil
                return try context.tokenizer.applyChatTemplate(
                    messages: [["role": "user", "content": text]],
                    tools: noTools,
                    additionalContext: noContext
                ).count
            }
        } catch {
            return nil
        }
    }
}

// MARK: - Reasoning-template normalisation

extension MLXGemmaProvider {
    /// Whether the model family's chat template pre-opens `<think>` in the
    /// generation prompt, so the model emits only the CLOSING tag. Verified in
    /// Qwen3.5's chat_template.jinja (both 2B and 9B). Qwen3 re-emits its own
    /// opening tag in the output, so it is deliberately NOT listed.
    static func templatePreOpensThink(for configuration: ModelConfiguration) -> Bool {
        let modelName = configuration.name.lowercased()
        // Bonsai-27B is qwen3_5 under a brand id with no qwen spelling — its
        // template ends the generation prompt with an opened <think> (verified
        // against the HF chat_template.jinja 2026-07-17). Exact size id, per
        // the #41 doctrine: the 8B is dense Qwen3 and must NOT match.
        return modelName.contains("qwen3.5") || modelName.contains("qwen3_5")
            || modelName.contains("qwen3-5") || modelName.contains("ternary-bonsai-27b")
    }

    /// Whether the family's chat template understands the `enable_thinking` switch
    /// — i.e. fast mode can suppress the think phase by rendering
    /// `enable_thinking:false`. This spans the WHOLE Qwen3 family (3 AND 3.5);
    /// keep it DISTINCT from `templatePreOpensThink` (a 3.5-only quirk about
    /// pre-opening the `<think>` tag). Conflating the two is what silently disabled
    /// fast mode after the dense-Qwen3 swap (#94): plain Qwen3 toggles thinking but
    /// does not pre-open, so tying toggle-support to the pre-open check meant
    /// `enable_thinking:false` was never sent and the model thought on every turn.
    static func templateSupportsThinkingToggle(for configuration: ModelConfiguration) -> Bool {
        // "qwen3" matches Qwen3-4B/8B AND every Qwen3.5 spelling (which contains it).
        // The 2507 refresh is EXCLUDED: Qwen split it into fixed-mode variants
        // (Instruct never thinks, Thinking always does) and dropped
        // enable_thinking from both templates (verified 2026-07-16) — claiming
        // the toggle would leave the reasoning picker a dead control. The
        // Instruct variant is the wired lil since 2026-07-16.
        let name = configuration.name.lowercased()
        // Bonsai-27B's qwen3_5 template reads enable_thinking (verified against
        // the HF chat_template.jinja 2026-07-17) — the 8B stays out (its
        // template carries no switch, pinned 2026-07-15).
        return (name.contains("qwen3") && !name.contains("2507"))
            || name.contains("ternary-bonsai-27b")
    }

    /// Whether the model this provider serves can consume attached images —
    /// true exactly when it loads through the VLM factory (vision tower
    /// resident). Read by the tool-session mapping to decide whether images
    /// ride the chat render or are dropped.
    public var supportsImageInput: Bool {
        Self.usesVLMLoadPath(for: ModelConfiguration(id: modelIdentifier))
    }

    /// Whether this checkpoint loads through VLMModelFactory (vision tower +
    /// audio embedder resident) instead of MLXLLM's text-only strip.
    ///
    /// Exact-id allow-list on purpose (the supportsQuantizedKVCache pattern):
    /// gemma-4-12B is PROVEN to load + generate under MLXVLM on-device
    /// (GemmaVisionSpike 2026-07-14, GemmaMTPSpike 2026-07-19 — RAM ≈ the
    /// text-only load's), and the VLM path is what unlocks image input and,
    /// once upstream wires Gemma4Unified's MTP entry point, the speculative
    /// drafter. e4b must NOT route here: upstream's Gemma4Unified sanitize
    /// lacks the KV-shared-layer fix (e4b has 18 shared layers → keyNotFound
    /// layers.24.self_attn.v_proj at load; 12B has 0). Unknown ids default to
    /// the known-good LLM factory.
    static func usesVLMLoadPath(for configuration: ModelConfiguration) -> Bool {
        configuration.name.lowercased().contains("gemma-4-12b")
    }

    /// Allow-list of families whose attention routes through upstream's
    /// `attentionWithCacheUpdate` dispatcher (handles `QuantizedKVCache` via
    /// `updateQuantized`). Gemma3nText and Gemma4Text call
    /// `cache.update(keys:values:)` directly — an upstream fatalError on a
    /// quantized cache — so they (and unknown families) stay unquantized.
    /// Verified against the model sources at mlx-swift-lm 3.31.3; re-audit on
    /// any version bump.
    static func supportsQuantizedKVCache(for configuration: ModelConfiguration) -> Bool {
        let modelName = configuration.name.lowercased()
        // "qwen3" covers Qwen3 and every Qwen3.5 spelling; "gemma-3-" cannot
        // match gemma-3n ids ("gemma-3n…" has no trailing dash after the 3).
        // Ternary-Bonsai-8B (prism-ml) is dense Qwen3 under a brand id —
        // model_type "qwen3" → Qwen3Model → attentionWithCacheUpdate, so
        // quantized KV routes safely (verified against the 8B config 2026-07-15).
        // The 27B is qwen3_5 (config verified 2026-07-17): Qwen35Model's
        // full-attention layers route through attentionWithCacheUpdate too
        // (Qwen35.swift:367, re-audited at 3.31.4), and quantized KV ran in
        // production on this arch when lil was Qwen3.5-4B — the old
        // unverified-default exclusion lifts. Still exact size ids on purpose.
        return modelName.contains("qwen3") || modelName.contains("gemma-3-")
            || modelName.contains("ternary-bonsai-8b")
            || modelName.contains("ternary-bonsai-27b")
    }

    /// Whether this model benefits from a window-sized prefill chunk.
    ///
    /// True for gemma-4, measured: its own default chunk is smaller than its
    /// sliding window and costs ~8.5% of every turn's prefill. Deliberately a
    /// narrow allow-list rather than a default for everything — the sibling
    /// `supportsCallerKVCapacity` has now been broken twice by unscoped family
    /// assumptions, and an unmeasured model deserves upstream's choice, not
    /// ours.
    static func prefersWindowSizedPrefill(for configuration: ModelConfiguration) -> Bool {
        configuration.name.lowercased().contains("gemma-4")
    }

    /// A model's attention window, when it is SMALLER than its context length —
    /// i.e. a sliding window that the KV cache rotates through.
    ///
    /// gemma-4 slides at 1024. Nil means "no sliding window" (dense attention,
    /// e.g. Qwen3), where a cached prefix stays linearly trimmable and reuse
    /// works for real.
    static func slidingWindow(forModelID modelID: String) -> Int? {
        modelID.lowercased().contains("gemma-4") ? 1024 : nil
    }

    /// Whether a persona prefix of `tokens` can ever be REUSED on this model.
    ///
    /// Measured 2026-08-09: a prefix longer than the sliding window wraps the
    /// rotating KV cache, `isTrimmable` goes false, and MLXToolCalling's
    /// `reusable` gate vetoes cross-turn reuse — permanently, for every turn.
    /// On gemma-4 the persona is ~1878 tokens against a 1024 window, so it is
    /// ALWAYS in that regime, and building it cost 12.5 SECONDS of prefill per
    /// launch and per brain swap to produce a cache nothing could ever use.
    ///
    /// The old code documented this ("a wrapped prefix can't be linearly reused
    /// anyway") and built it regardless. Knowing it is wasted is not the same as
    /// not doing it.
    static func prefixIsReusable(tokens: Int, modelID: String) -> Bool {
        guard let window = slidingWindow(forModelID: modelID) else { return true }
        return tokens <= window
    }

    /// Whether a caller-requested KV capacity (`maxKVSize`) means anything for
    /// this model — i.e. whether it rides upstream's DEFAULT `newCache`, which
    /// builds one `RotatingKVCache(.requested)` per layer.
    ///
    /// **An ALLOW-list, defaulting to false.** 27 of upstream's models override
    /// `newCache` to build their own per-layer geometry and ignore
    /// `parameters` outright — Gemma4Text (`StandardKVCache` for
    /// `full_attention` layers, modelNative `RotatingKVCache(slidingWindow)`
    /// for the rest) and LFM2Model (`KVCacheSimple` + `MambaCache`) are both in
    /// that set, as are the Mamba/Jamba/Granite/Nemotron/Qwen3Next hybrids. For
    /// every one of them our 8192 backstop was **always a silent no-op**.
    ///
    /// mlx-swift-lm's typed KV-cache validation (#453, 2026-08-05) turned that
    /// silent no-op into a hard throw —
    /// `incompatibleCapacity(expected: 8192, count: 8)`. It took gemma-4
    /// tool-use from 5/5 to **0/5**, and then took LFM2.5 from a real
    /// evaluation to **0/44** even after its weights loaded cleanly. The first
    /// cut of this predicate was a DENY-list with a permissive default, which
    /// is what let LFM2.5 through; the asymmetry says otherwise:
    ///
    /// - wrongly REQUESTING a capacity → the model fails outright, every turn;
    /// - wrongly OMITTING one → we forgo a rotation backstop that the per-turn
    ///   session lifecycle and `maxTokens` already bound in practice.
    ///
    /// So an unproven family gets no capacity — the same crash-safe-over-fast
    /// shape as `supportsQuantizedKVCache`. Add a family here only after
    /// confirming it has no `newCache` override in mlx-swift-lm.
    static func supportsCallerKVCapacity(for configuration: ModelConfiguration) -> Bool {
        let modelName = configuration.name.lowercased()
        // ⚠️ VERSION-SCOPED ON PURPOSE. Llama-3 has no newCache override
        // (verified against mlx-swift-lm at revision c97539da) — it takes
        // upstream's default, which honours a requested capacity by building
        // RotatingKVCache(.requested) per layer.
        //
        // The prefix is "llama-3", not "llama", because this function has now
        // been broken TWICE by exactly that kind of unscoped family assumption:
        // Gemma-3 honoured the capacity, Gemma-4 silently stopped, and LFM2
        // never did. A future Llama-4 (or a vision/guard/MoE variant) could
        // add a newCache override the same way and would be matched silently
        // by a bare "llama". It also avoids matching an id containing
        // "ollama". **Audit `newCache` upstream before adding a family here.**
        return modelName.contains("llama-3")
    }

    /// Prepend the synthetic `<think>` opener exactly once so downstream
    /// reasoning splitting always sees a well-formed pair. No-op when the
    /// template didn't pre-open, the text already opens one, or there is no
    /// text at all.
    static func normaliseThinkPrefix(_ text: String, preOpened: Bool) -> String {
        guard preOpened, !text.isEmpty, !text.hasPrefix("<think>") else { return text }
        return "<think>" + text
    }
}

// MARK: - Raw (persona-free) completion — Brain at Home /v1/generate

/// A completion with NOTHING in context but the caller's prompt: no persona
/// KV seed, no instructions, no tools, no conversation tail. Built for the
/// Brain at Home raw route — a network-reachable session primed with the
/// persona (About-the-user block included) is a prefix-extraction surface,
/// so raw-ness is structural, not filtered (2026-08-19 audit, finding 1).
extension MLXGemmaProvider: RawCompletionProviding {
    public func generateRawStreaming(prompt: String, maxTokens: Int?) -> AsyncStream<String>? {
        AsyncStream { continuation in
            let task = Task {
                defer { MLXMemoryBudget.reclaim(label: "generateRawStreaming") }
                do {
                    let container = try await ensureLoaded()
                    var parameters = generateParameters
                    if let requested = maxTokens {
                        // Remote callers may SHORTEN a generation, never
                        // lengthen it past this provider's own cap.
                        let cap = parameters.maxTokens ?? Self.defaultMaxTokens
                        parameters.maxTokens = min(max(1, requested), cap)
                    }
                    // instructions: nil and no cache seed — the raw contract.
                    let session = ChatSession(container, generateParameters: parameters)
                    for try await event in session.streamDetails(to: prompt, images: [], videos: []) {
                        if let chunk = event.chunk { continuation.yield(chunk) }
                        if let info = event.info {
                            logGenerationInfo(
                                info, label: "raw", model: modelIdentifier,
                                totalContextTokens: info.promptTokenCount
                            )
                        }
                    }
                    continuation.finish()
                } catch {
                    if !(error is CancellationError) {
                        mlxTTFTLog.error("""
                        generateRawStreaming failed [\(self.modelIdentifier, privacy: .public)]: \
                        \(error.localizedDescription, privacy: .public)
                        """)
                    }
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
