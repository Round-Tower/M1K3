//
//  AgentRAGResponder.swift
//  M1K3Chat
//
//  The always-on tool-calling responder: every chat message runs the LocalAgent
//  ReAct loop with injected tools (web search, datetime, system status, …).
//
//  Retrieval still happens FIRST, exactly like RAGResponder — the chunks come
//  back as typed sources so ChatSession's citation validation is unchanged, and
//  a model that opens with CONCLUSION: costs exactly one generation, same as
//  plain RAG. The conclusion's tail streams live via the agent's
//  ConclusionStreamSplitter; tool use surfaces through onActivity; and if the
//  agent throws or comes back empty, we fall back to the plain grounded prompt
//  rather than failing the turn (AFM guardrails, format collapse — never a
//  dead bubble).
//
//  Signed: Kev + claude-fable-5, 2026-06-09, Confidence 0.8, Prior: Unknown
//  Context: tools are injected by the app layer (M1K3Chat does not link
//  M1K3AgentTools); web_search is only in the list when the user's setting
//  allows it.
//  Review: Kev + claude-fable-5, 2026-06-12, Confidence 0.85 — RULES line in
//  both styles routing self-questions (configuration/design/abilities) to the
//  persona instead of document search; the soft fix for meta-question
//  confabulation, taken over a pre-generation router (brittle both ways).
//  Review: Kev + claude-opus-4-8, 2026-06-13, Confidence 0.9 — retrieval now
//  uses store.searchGrounding (two-lane doc+memory budgets, memoryTopK) so the
//  document corpus can't crowd memory recall out of a single top-K. Fixes the
//  live open-chat miss (M1K3 forgot the user's own city). verify-at-⌘R.
//  Review: Kev + claude-opus-4-8, 2026-06-30, Confidence 0.9 — gather-then-
//  synthesise on the native path: once a tool runs, suppress the model's loose
//  in-loop conclusion (gemma free-forms content-free filler and ignores the
//  results) and answer explicitly over the gathered observations via fallBack.
//  ReAct's CONCLUSION: contract is untouched (gated on style == .native).
//  Diagnosed live — the conclusion was filler, not empty; instrument first.
//  Review: Kev + claude-opus-4-8, 2026-06-30, Confidence 0.85 — brain-aware
//  conversation replay: `grounding` now takes a `HistoryWindow.Budget` (per-tier,
//  from `HistoryBudgetPolicy`) so the multi-turn window scales to the brain. The
//  compose-fix that briefly lived here (trust `conclusionWasStreamed`) was
//  SUPERSEDED by the gather-then-synthesise approach above (verified on gemma,
//  the brain that actually fills); the persona-voiced composed answer on Qwen is
//  a tracked follow-up. Only the history-budget threading survives this merge.
//  Review: Kev + claude-fable-5, 2026-07-12, Confidence 0.85 — self-query
//  router (prompt-hardening v2, code-side): SelfQueryGate short-circuits
//  retrieval and withholds the corpus-reaching tools on questions about M1K3
//  itself, enforcing persona rule 3 in code. Narrow leak-class classifier,
//  NOT the general pre-generation router rejected 2026-06-12 — a miss falls
//  back to the prompt rule (today's behaviour); boundaries pinned in tests.
//  Review: Kev + claude-fable-5, 2026-07-20, Confidence 0.85 — the grounding-
//  size safety cap: right after GroundingGate.partition, GroundingBudget.fit
//  caps the combined chunks+memories to ~1100 tokens (measured, PR #65) before
//  anything renders them, closing the near-miss where gemma-4's grounded-Q
//  worst case landed at 2998/3000 reserve tokens. A `.notice` breadcrumb fires
//  only when the cap actually changed something — see GroundingBudget.swift.
//  (This line used to read "no-op when the provider isn't `TokenCounting`
//  (AFM/Mini)" — that exemption was the 2026-08-03 Mini bug. The cap now
//  applies on every tier, estimating when there is no exact tokenizer.)
//  Review: Kev + claude-fable-5, 2026-08-23, Confidence 0.8 — the hands:
//  when propose_script is offered, the generative carve-out gains ONE exception
//  (a runnable script routes to propose_script, not a pasted code block). The
//  absolutist "no tools" prohibition is KEPT for every other generative ask so
//  gemma never over-tools a poem/story — a review fold after the first draft
//  dropped it (would have let "write a story about the moon landing" fire
//  web_search). On-device A/B owed on the Big/gemma tier: script→sheet,
//  poem→inline, generative-with-a-fact→still-no-tool.
//  MurphySig: kevin+claude-fable-5 2026-08-23 confidence=0.8 — prompt content
//  is pin-tested; the behavioural change on gemma is verify-at-⌘R.

import Foundation
import M1K3Agent
import M1K3Inference
import M1K3Knowledge
import os
import Synchronization

public struct AgentRAGResponder: RAGResponding, Sendable {
    private static let log = Logger(subsystem: M1K3Log.subsystem, category: "responder")
    private let store: KnowledgeStore
    private let embedder: any EmbeddingService
    private let provider: any InferenceProvider
    /// Evaluated fresh each turn so a settings change (e.g. the web-search
    /// privacy toggle) applies immediately — a disabled tool is never even
    /// visible to the model.
    private let toolsProvider: @Sendable () -> [any AgentTool]
    private let topK: Int
    /// Memories get their OWN retrieval budget (see `KnowledgeStore.searchGrounding`)
    /// so document volume can't crowd them out of recall.
    private let memoryTopK: Int
    private let maxIterations: Int
    /// Hits the model retrieved itself via search_knowledge — drained after
    /// the stream and merged into the turn's sources (see `collectedSources`).
    private let sourceCollector: ToolSourceCollector?
    /// The user's reasoning preference, read fresh each turn (Settings picker:
    /// Auto / Always think / Fast answers) — same per-turn pattern as tools.
    private let thinkingModeProvider: @Sendable () -> ThinkingMode
    /// The active brain's display name (e.g. "Lil M1K3"), read fresh each turn so
    /// a runtime hot-swap is reflected — same per-turn pattern as `toolsProvider`.
    /// Empty when unknown (tests / simple callers); the context line omits it then.
    private let brainNameProvider: @Sendable () -> String
    /// Per-turn override for the agent-loop iteration cap, read FRESH each turn so
    /// a thermal "ease off" (CoolHeadPolicy) takes effect live without rebuilding
    /// the long-lived responder. `nil` → the fixed `maxIterations` base, so the
    /// default path is byte-identical. Stays an opaque `() -> Int`: the thermal
    /// level enum lives in M1K3LanguageModel, which this module deliberately does
    /// NOT link (the dependency-direction trap) — the enum→Int map is the app's job.
    private let maxIterationsProvider: (@Sendable () -> Int)?
    /// Whether the active brain biases toward fast answers (Mini/Lil), read fresh
    /// each turn like the other providers so a hot-swap takes effect immediately.
    /// Feeds `ThinkingPolicy.shouldThink(fastByDefault:)` — the speed tiers skip the
    /// think phase on plain grounded lookups. Default `false` = the heavy-tier
    /// behaviour, so existing callers/tests are byte-identical.
    private let fastThinkingProvider: @Sendable () -> Bool
    /// The conversation-replay budget, read FRESH each turn (same per-turn pattern
    /// as the other providers) so a brain hot-swap re-sizes the window immediately —
    /// wide on the dense-Qwen tiers, clamped under gemma-4's 8192 rotating window.
    /// Defaults to the conservative shipped window so an unwired caller is unchanged.
    private let historyBudgetProvider: @Sendable () -> HistoryWindow.Budget
    /// Cool Head's heavy-generation defer, read FRESH each turn. `true` (critical
    /// thermal + opt-in ON) makes the turn skip the heavy retrieve+generate and
    /// answer with an honest deferral instead of piling onto a throttling Mac.
    /// `nil` → never defers, so the default path is byte-identical. Opaque
    /// `() -> Bool` for the same dependency-direction reason as `maxIterationsProvider`:
    /// the CoolHeadLevel enum lives in M1K3LanguageModel, which this module doesn't link.
    private let defersHeavyGenerationProvider: (@Sendable () -> Bool)?
    /// The grounding token ceiling, read FRESH each turn like the other
    /// providers so a brain hot-swap re-sizes it immediately.
    /// `GroundingBudget.defaultTokenBudget` was DERIVED from Big's 3000-token
    /// reserve in an 8192-token window; on Mini's 4096 window the same number is
    /// 27% of everything the model has. `GroundingBudgetPolicy` sizes it per
    /// tier. Defaults to the old constant so unwired callers are byte-identical.
    private let groundingBudgetProvider: @Sendable () -> Int

    public init(
        store: KnowledgeStore,
        embedder: any EmbeddingService,
        provider: any InferenceProvider,
        toolsProvider: @escaping @Sendable () -> [any AgentTool],
        topK: Int = 5,
        memoryTopK: Int = 5,
        maxIterations: Int = 3,
        sourceCollector: ToolSourceCollector? = nil,
        thinkingModeProvider: @escaping @Sendable () -> ThinkingMode = { .auto },
        brainNameProvider: @escaping @Sendable () -> String = { "" },
        fastThinkingProvider: @escaping @Sendable () -> Bool = { false },
        historyBudgetProvider: @escaping @Sendable () -> HistoryWindow.Budget = { .default },
        maxIterationsProvider: (@Sendable () -> Int)? = nil,
        defersHeavyGenerationProvider: (@Sendable () -> Bool)? = nil,
        groundingBudgetProvider: @escaping @Sendable () -> Int = { GroundingBudget.defaultTokenBudget }
    ) {
        self.store = store
        self.embedder = embedder
        self.provider = provider
        self.toolsProvider = toolsProvider
        self.topK = topK
        self.memoryTopK = memoryTopK
        self.maxIterations = maxIterations
        self.sourceCollector = sourceCollector
        self.thinkingModeProvider = thinkingModeProvider
        self.brainNameProvider = brainNameProvider
        self.maxIterationsProvider = maxIterationsProvider
        self.fastThinkingProvider = fastThinkingProvider
        self.historyBudgetProvider = historyBudgetProvider
        self.defersHeavyGenerationProvider = defersHeavyGenerationProvider
        self.groundingBudgetProvider = groundingBudgetProvider
    }

    /// Fixed tool list — convenience for tests and simple callers.
    public init(
        store: KnowledgeStore,
        embedder: any EmbeddingService,
        provider: any InferenceProvider,
        tools: [any AgentTool],
        topK: Int = 5,
        maxIterations: Int = 3
    ) {
        self.init(
            store: store, embedder: embedder, provider: provider,
            toolsProvider: { tools }, topK: topK, maxIterations: maxIterations
        )
    }

    /// History-free entry points (tests, simple callers): same turn, no replay.
    /// Both forward UP to the real (history) implementation — the protocol's
    /// one-way defaults would forward DOWN to the plain variant and bypass it.
    public func answerStreaming(
        _ question: String
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        try await answerStreaming(question, history: [], onActivity: { _ in })
    }

    public func answerStreaming(
        _ question: String,
        onActivity: @escaping @Sendable (ResponderActivity) -> Void
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        try await answerStreaming(question, history: [], onActivity: onActivity)
    }

    /// The honest line M1K3 gives when Cool Head defers a heavy turn (critical
    /// thermal). Warm, brief, and truthful — never a silent non-answer.
    static let coolHeadDeferralMessage =
        "My \(HostPlatform.noun)'s gone properly warm, so I'm easing off the heavy thinking for a "
            + "moment to let it cool down. Give it a minute and ask me again."

    public func answerStreaming(
        _ question: String,
        history: [ChatTurn],
        onActivity: @escaping @Sendable (ResponderActivity) -> Void
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        try await answerStreaming(question, images: [], history: history, onActivity: onActivity)
    }

    public func answerStreaming(
        _ question: String,
        images: [ImageAttachment],
        history: [ChatTurn],
        onActivity: @escaping @Sendable (ResponderActivity) -> Void
    ) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        // Cool Head at minimal (critical thermal, opt-in ON): skip the whole heavy
        // path — no embed, no retrieval, no decode — and answer honestly instead of
        // piling onto a throttling Mac. The caller (ChatSession) has already recorded
        // the user's turn, so this just fills the assistant bubble; the transcript is
        // intact. Default path (provider nil/false) is byte-identical.
        if defersHeavyGenerationProvider?() == true {
            let message = Self.coolHeadDeferralMessage
            let stream = AsyncStream<String> { continuation in
                continuation.yield(message)
                continuation.finish()
            }
            return (sources: [], stream: stream)
        }

        // Pre-generation phase instrument: the 2026-08-10 eval found 177s of
        // total log silence before a turn's first model call — "turn start:"
        // only fires after retrieval, so a blocked embed was invisible. One
        // line per turn now names where the pre-gen time went.
        let phaseClock = ContinuousClock()
        var phases = TurnPhaseTimeline()
        phases.started(at: phaseClock.now)
        // Stale tool hits from an aborted prior turn must not leak in.
        _ = sourceCollector?.drain()
        // Self-query router (prompt-hardening v2): a question about M1K3
        // itself never touches retrieval — nothing embedded, nothing injected
        // — and the corpus-reaching tools are withheld from the turn below.
        // Persona rule 3 states this policy; the gate enforces it in code.
        let isSelfQuery = SelfQueryGate.isSelfQuery(question)
        var chunks: [ChunkHit]
        var memories: [ChunkHit]
        if isSelfQuery {
            Self.log.notice("self-query gate: retrieval skipped, corpus tools withheld")
            (chunks, memories) = ([], [])
        } else {
            onActivity(.retrieving)
            let queryVector = try await embedder.embedQuery(question)
            phases.embedded(at: phaseClock.now)
            // Two-lane retrieval: documents and memories get SEPARATE top-K budgets
            // so the larger document corpus can't crowd short memory facts out of a
            // single ranking (the open-chat recall miss — M1K3 forgot the user's
            // own city when the query leaned even slightly documentary).
            let retrieved = try store.searchGrounding(
                query: question, queryVector: queryVector,
                documentLimit: topK, memoryLimit: memoryTopK
            )
            // Gate on relevance: each lane ALWAYS returns something, even for "what
            // model are you?" — weak hits pollute the prompt and derail small
            // models. Below threshold nothing is injected; the model can still
            // retrieve on its own terms via search_knowledge. Memory hits clear
            // their own (lower) bar and feed a separate uncited prompt block.
            // Floors follow the ACTIVE embedder's cone (hashing fallback ≠
            // instructed qwen3) — resolved per turn because the swappable
            // façade can flip embedders at runtime.
            (chunks, memories) = GroundingGate.partition(
                retrieved, floors: .forFingerprint(embedder.fingerprint)
            )
            Self.logGateDecision(retrieved: retrieved, kept: chunks + memories)
            phases.retrieved(at: phaseClock.now)
        }
        // Grounding-size safety cap (2026-07-20): both lanes above are injected
        // VERBATIM and UNTRUNCATED downstream (groundingBody). On gemma-4-12B
        // ("Big"), PR #65's prompt-size instrument measured the grounded-Q worst
        // case at 2998 of a 3000-token reserve — 2 tokens of headroom before
        // `RotatingKVCache(8192)` silently rotates the persona/grounding head out
        // mid-turn with NO error. GroundingBudget caps at the source instead —
        // on EVERY tier. When this turn's provider has no tokenizer (AFM/Mini)
        // the cap estimates rather than standing down: the exemption this
        // comment used to describe ("AFM/Mini self-manage their own windows")
        // was the 2026-08-03 bug, and Mini's window is the smallest of the lot
        // at 4096 tokens.
        let beforeCapChunks = chunks
        let beforeCapMemories = memories
        let countTokens: (String) async -> Int? = { [provider] text in
            await (provider as? TokenCounting)?.tokenCount(text)
        }
        let groundingTokenBudget = groundingBudgetProvider()
        (chunks, memories) = await GroundingBudget.fit(
            chunks: chunks, memories: memories,
            tokenBudget: groundingTokenBudget,
            countTokens: countTokens
        )
        // Marked BEFORE the diagnostic block below — its extra tokenizer
        // passes are logging overhead, and folding them into "cap Xms" would
        // make the instrument distort the thing it measures.
        phases.capped(at: phaseClock.now)
        if chunks != beforeCapChunks || memories != beforeCapMemories {
            // Only pay for the extra tokenizer passes when the cap actually did
            // something — the common case (nothing dropped, or no tokenizer at
            // all) never recomputes totals just to decide whether to log.
            let beforeTokens = await GroundingBudget.totalTokens(
                chunks: beforeCapChunks, memories: beforeCapMemories, countTokens: countTokens
            )
            let afterTokens = await GroundingBudget.totalTokens(
                chunks: chunks, memories: memories, countTokens: countTokens
            )
            Self.log.notice(
                """
                grounding cap: units \(beforeCapChunks.count + beforeCapMemories.count)\
                →\(chunks.count + memories.count), tokens \(beforeTokens)→\(afterTokens)
                """
            )
        }
        // Snapshot as `let` for the closure below — `chunks`/`memories` are
        // `var` only so the cap above could reassign them; a `var` capture in
        // a Task closure is a Swift 6 sending-risk error even though nothing
        // mutates them again after this point.
        let cappedChunks = chunks
        let cappedMemories = memories
        // Resolve the tool list once per turn; the routing rules must match
        // what's actually callable (no advertising a disabled web_search).
        // On a self-query turn the retrieval tools are withheld entirely —
        // the model cannot call what it is never offered.
        let tools = isSelfQuery
            ? toolsProvider().filter { !SelfQueryGate.withheldToolNames.contains($0.name) }
            : toolsProvider()

        let stream = AsyncStream<String> { continuation in
            let turnTask = Task {
                await runAgentTurn(
                    question: question,
                    images: images,
                    chunks: cappedChunks,
                    memories: cappedMemories,
                    history: history,
                    tools: tools,
                    onActivity: onActivity,
                    continuation: continuation
                )
            }
            // The Task above is NOT a child of the stream's consumer, so the
            // consumer cancelling (user sends a new message mid-loop, voice
            // mode bails) would otherwise leave the agent loop running to the
            // iteration cap. Terminating the stream cancels the turn.
            continuation.onTermination = { _ in turnTask.cancel() }
        }
        phases.handedOff(at: phaseClock.now)
        if let phaseLine = phases.summary(gate: isSelfQuery ? .selfQuery : .normal) {
            Self.log.notice("\(phaseLine, privacy: .public)")
        }
        // Memory hits ride along as sources so the UI shows their provenance.
        return (cappedChunks + cappedMemories, stream)
    }

    /// Grounding for the think-phase decision counts BOTH retrieval lanes: a
    /// turn grounded only by a memory hit (0 doc chunks) is still a grounded
    /// answer and earns CoT on the heavy tiers, same as a document hit.
    static func hasGroundedKnowledge(chunks: [ChunkHit], memories: [ChunkHit]) -> Bool {
        !chunks.isEmpty || !memories.isEmpty
    }

    /// One full agent turn into `continuation`: run the loop (conclusion tail
    /// streams live), then the web-sources tail, with the plain-RAG fallback
    /// on throw or empty.
    private func runAgentTurn(
        question: String,
        images: [ImageAttachment],
        chunks: [ChunkHit],
        memories: [ChunkHit],
        history: [ChatTurn],
        tools: [any AgentTool],
        onActivity: @escaping @Sendable (ResponderActivity) -> Void,
        continuation: AsyncStream<String>.Continuation
    ) async {
        // Match the loop LocalAgent will actually run (same capability check),
        // so the native path never sees the ReAct format scaffold.
        let style: Self.PromptStyle =
            (provider as? ToolCallingProvider)?.supportsToolCalls == true ? .native : .react
        // The per-turn truth: today's precise date + which brain is answering.
        // Prepended here (not inside `grounding`, which stays pure/testable) so it
        // rides the variable grounding, never the cached persona prefix.
        let contextLine = PromptContext.line(now: Date(), brainName: brainNameProvider())
        let grounding = contextLine + "\n\n" + Self.grounding(
            chunks: chunks, memories: memories, toolNames: Set(tools.map(\.name)),
            history: history,
            historyBudget: historyBudgetProvider().reservingImages(images.count),
            style: style
        )
        Self.logTurnStart(chunks: chunks, tools: tools, grounding: grounding)
        // Fresh agent per turn — its reasoning trace must not bleed across
        // turns, and the tool list reflects current settings. The iteration cap is
        // read fresh too: `nil` keeps the configured base, else the live thermal
        // budget (never snapshotted at build time — the responder is long-lived).
        let iterations = maxIterationsProvider?() ?? maxIterations
        let agent = LocalAgent(
            inferenceProvider: provider,
            tools: tools,
            maxIterations: iterations,
            concludesOnUnstructuredThought: true
        )
        // Per-turn reasoning budget: casual asks skip the think phase
        // entirely (instant answers); grounded/analytic asks keep it.
        let thinkingEnabled = ThinkingPolicy.shouldThink(
            question: question,
            hasGroundedKnowledge: Self.hasGroundedKnowledge(chunks: chunks, memories: memories),
            mode: thinkingModeProvider(),
            fastByDefault: fastThinkingProvider()
        )
        // A direct answer streams live only until the FIRST tool runs. After that
        // the model's free-form in-loop conclusion is unreliable — gemma emits a
        // content-free "let me look" preamble and ignores what the tools actually
        // returned (seen live). So once a tool dispatches we suppress the loose
        // conclusion and, when the loop ends, synthesise explicitly over the
        // gathered observations (gemma's competent grounded path) via `fallBack`.
        let emittedLive = Mutex(false)
        let toolUsed = Mutex(false)
        do {
            let result = try await agent.run(
                goal: question,
                images: images,
                context: grounding,
                thinkingEnabled: thinkingEnabled,
                onEvent: { event in
                    if case .actionStarted = event { toolUsed.withLock { $0 = true } }
                    Self.forward(event, to: onActivity)
                },
                onConclusionToken: { token in
                    // Native small models free-form a content-free "let me look"
                    // preamble AFTER a tool and ignore what it returned, so once a
                    // tool runs we suppress the loose conclusion and synthesise
                    // explicitly below. The ReAct floor's CONCLUSION: contract is
                    // reliable — never suppress it (it carries the real answer).
                    if style == .native, toolUsed.withLock({ $0 }) { return }
                    emittedLive.withLock { $0 = true }
                    continuation.yield(token)
                },
                // Chain-of-thought streams into the same chat stream — the
                // chat-side splitter routes it to the reasoning disclosure.
                // Deliberately does NOT set emittedLive: reasoning alone is
                // not an answer, so the synthesis/fallback still fires.
                onReasoningToken: { token in
                    continuation.yield(token)
                }
            )

            let conclusion = result.conclusion
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let streamed = emittedLive.withLock { $0 }
            // Native tool turns ALWAYS synthesise via fallBack: gemma's loose
            // in-loop conclusion is unreliable filler, so even an error-only or
            // empty gather must route through fallBack (which filters errors and
            // degrades to plain RAG) rather than surface that conclusion. The
            // ReAct path keeps its reliable CONCLUSION:. Both still use the
            // empty-conclusion fallback for the no-tool case.
            let synthesiseOverEvidence = style == .native && !result.toolsUsed.isEmpty
            if synthesiseOverEvidence || (!streamed && conclusion.isEmpty) {
                await fallBack(
                    question: question, chunks: chunks, contextLine: contextLine,
                    result: result, into: continuation
                )
            } else {
                var tail = streamed ? "" : conclusion
                tail += Self.webSourcesBlock(for: result)
                tail += Self.factSourcesBlock(for: result)
                if !tail.isEmpty {
                    continuation.yield(tail)
                }
                Self.logTurnDone(
                    streamed: streamed, tailCount: tail.count, result: result
                )
            }
            continuation.finish()
        } catch is CancellationError {
            Self.log.notice("turn cancelled mid-loop")
            continuation.finish()
        } catch {
            Self.log.error("agent threw — falling back to plain RAG: \(error, privacy: .public)")
            await streamFallback(question: question, chunks: chunks, contextLine: contextLine, into: continuation)
            continuation.finish()
        }
    }

    /// Sources the model gathered itself via search_knowledge this turn —
    /// merged into the message's sources (and the citation allow-list) by
    /// ChatSession once the stream completes.
    public func collectedSources() -> [ChunkHit] {
        sourceCollector?.drain() ?? []
    }

    /// One line per retrieved hit with both relevance signals, so the gate
    /// thresholds can be tuned on real queries from the unified log.
    private static func logGateDecision(retrieved: [ChunkHit], kept: [ChunkHit]) {
        let keptIDs = Set(kept.map(\.chunkID))
        for hit in retrieved {
            let similarity = hit.similarity.map { String(format: "%.3f", $0) } ?? "–"
            let fused = hit.rrfScore.map { String(format: "%.4f", $0) } ?? "–"
            let verdict = keptIDs.contains(hit.chunkID) ? "kept" : "gated"
            let chunk = hit.chunkID.uuidString
            // .notice, like the summary line below and for the same reason: this
            // is the ONLY instrument that can say what a wrong hit actually
            // scored, and .debug does not persist in OSLogStore — so every
            // question about the floors was being answered from inference. Asked
            // for by name on 2026-08-12 after a screenplay was retrieved for a
            // question about dinner: measure before moving a threshold.
            //
            // ★ ID, never the TITLE. The title was here while this was `.debug`,
            // which the logging daemon does not persist; promoting the line to
            // `.notice` would have carried document titles into `OSLogStore` and
            // from there into the issue report — the one deliberate exception to
            // "nothing leaves this device" — where the scrub knows about paths,
            // emails and the user's name, but has no notion of corpus content. A
            // title can BE the sensitive part ("MRI results.pdf", someone's name).
            // The sibling quarantine sweeps in this same change log ids only for
            // exactly this reason. Map an id back with `get_document` or a store
            // query when a hit needs identifying; the score is what the
            // instrument exists to report.
            log.notice(
                "gate \(verdict, privacy: .public): sim=\(similarity, privacy: .public) rrf=\(fused, privacy: .public) chunk=\(chunk, privacy: .public)"
            )
        }
        let retrievedCount = retrieved.count
        let keptCount = kept.count
        // .notice (not .info): the gate decision is load-bearing for diagnosing a
        // bad retrieval from a captured issue report, where .info/.debug don't persist.
        log.notice("grounding gate: kept \(keptCount)/\(retrievedCount)")
    }

    /// Map agent-loop events to UI activity.
    private static func forward(
        _ event: AgentLoopEvent,
        to onActivity: @Sendable (ResponderActivity) -> Void
    ) {
        switch event {
        case let .thinking(iteration):
            onActivity(.thinking(iteration: iteration))
        case let .actionStarted(tool, argument):
            onActivity(.usingTool(name: tool, argument: argument))
        }
    }

    // MARK: - Diagnostics (unified logging)

    private static func logTurnStart(chunks: [ChunkHit], tools: [any AgentTool], grounding: String) {
        let toolNames = tools.map(\.name).sorted().joined(separator: ", ")
        // .notice: retrieval count + grounding size at turn start is a primary
        // breadcrumb — it must survive into a default-level issue-report capture.
        log.notice("""
        turn start: \(chunks.count) chunk(s) retrieved, tools=[\(toolNames, privacy: .public)], \
        grounding=\(grounding.count) chars
        """)
    }

    private static func logTurnDone(streamed: Bool, tailCount: Int, result: AgentResult) {
        let toolsUsed = result.toolsUsed.sorted().joined(separator: ", ")
        log.info("""
        turn done: streamedLive=\(streamed), tail=\(tailCount) chars, \
        toolsUsed=[\(toolsUsed, privacy: .public)]
        """)
    }

    /// The loop produced nothing usable as an answer — but its tools may have
    /// gathered real information. Synthesise from that (plain RAG only when
    /// there's truly nothing), keeping the deterministic web-sources block.
    private func fallBack(
        question: String,
        chunks: [ChunkHit],
        contextLine: String,
        result: AgentResult,
        into continuation: AsyncStream<String>.Continuation
    ) async {
        let steps = result.reasoningTrace.count
        Self.log.notice("agent returned empty (nothing streamed) — falling back with \(steps) trace step(s)")
        await streamFallback(
            question: question, chunks: chunks, contextLine: contextLine,
            gathered: result.reasoningTrace, into: continuation
        )
        let provenance = Self.webSourcesBlock(for: result) + Self.factSourcesBlock(for: result)
        if !provenance.isEmpty {
            continuation.yield(provenance)
        }
    }

    /// Grounded generation — the safety net when the agent loop fails. Uses
    /// the tool observations the loop already gathered when there are any
    /// (don't throw away a good web search because the model fumbled the
    /// CONCLUSION format), else the plain RAG prompt. Only ever runs when
    /// nothing has been yielded, so the raw provider chunks (cumulative or
    /// delta) fold correctly downstream.
    private func streamFallback(
        question: String,
        chunks: [ChunkHit],
        contextLine: String,
        gathered: [ReasoningStep] = [],
        into continuation: AsyncStream<String>.Continuation
    ) async {
        let body = Self.fallbackPrompt(question: question, chunks: chunks, gathered: gathered)
        // Carry the same per-turn context (precise date + active brain) the agent
        // path got, so a "what day is it?" that collapses to the fallback still answers.
        let prompt = contextLine.isEmpty ? body : contextLine + "\n\n" + body
        for await chunk in provider.generateStreaming(prompt: prompt) {
            continuation.yield(chunk)
        }
    }

    /// Pure fallback-prompt assembly: informative tool observations win;
    /// otherwise the standard grounded prompt.
    static func fallbackPrompt(
        question: String, chunks: [ChunkHit], gathered: [ReasoningStep]
    ) -> String {
        let observations = gathered.compactMap { step -> String? in
            guard let action = step.action,
                  let observation = step.observation,
                  !observation.hasPrefix("Error"),
                  !observation.hasPrefix("You already ran")
            else { return nil }
            return "\(action):\n\(observation)"
        }
        guard !observations.isEmpty else {
            return ChatPromptBuilder.build(chunks: chunks, userMessage: question)
        }
        return """
        Answer the user's question using the INFORMATION GATHERED below. Be \
        direct and plain — do not mention tools or actions.

        First check the gathered information actually answers the question. If it \
        does NOT establish that the thing asked about exists — it only mentions the \
        words separately, or covers a related-but-different topic — say plainly you \
        couldn't confirm it, and don't present a guess as fact. Do NOT stitch \
        tangential mentions into an affirmative answer.

        INFORMATION GATHERED:
        \(observations.joined(separator: "\n\n"))

        USER: \(question)
        """
    }

    /// Which loop the prompt is feeding. The ReAct floor NEEDS its format
    /// scaffold (CONCLUSION:/call budget); the native loop speaks structured
    /// calls, and feeding it the ReAct scaffold makes reasoning models burn
    /// their think budget obeying a format they never emit (seen live on
    /// Qwen3.5-9B agonising over "CONCLUSION:" for a casual greeting).
    enum PromptStyle {
        case react
        case native
    }

    /// The grounding handed to the agent: the retrieved knowledge (with the
    /// same citation labels the validator expects) + tight behavioral rules
    /// tuned for small models. The tool-routing lines match what's actually
    /// callable — never advertise a disabled web_search (and never imply
    /// search_knowledge can reach the live world; the ⌘R weather bug).
    static func grounding(
        chunks: [ChunkHit], memories: [ChunkHit] = [], toolNames: Set<String>,
        history: [ChatTurn] = [], historyBudget: HistoryWindow.Budget = .default,
        style: PromptStyle = .react, now: Date = Date()
    ) -> String {
        let body = groundingBody(
            chunks: chunks, memories: memories, toolNames: toolNames, style: style, now: now
        )
        guard let replay = HistoryWindow.render(history, budget: historyBudget) else { return body }
        return "\(replay)\n\n\(body)"
    }

    /// The uncited personal-facts block: memories aren't sources to cite,
    /// they're things M1K3 simply knows about the user. Sits between
    /// KNOWLEDGE and RULES; absent when no memory cleared the gate.
    ///
    /// Tier 1 (scratch/dream-cycle/SPEC.md): dated hits render newest-first
    /// with a "(learned …)" prefix so the model resolves contradictions with
    /// recency, at read time. Undated hits (pre-Tier-1 payloads, fixtures)
    /// keep the byte-pinned bare line and sort after dated ones. Token cost:
    /// ~6–8 tokens per dated fact, outside GroundingBudget.fit's accounting —
    /// covered by the ~95-token slack between the 1100 cap and the ~1195
    /// measured reserve (07-20 instrument run), so not re-plumbed.
    private static func memoryBlock(_ memories: [ChunkHit], now: Date) -> String? {
        guard !memories.isEmpty else { return nil }
        let ordered = memories.sorted {
            ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
        }
        // `-> String` is load-bearing: without it the two-return closure's
        // interpolations infer GRDB.SQL (also ExpressibleByStringInterpolation
        // in this module) and the block renders an SQL debug dump.
        let facts = ordered.map { hit -> String in
            guard let createdAt = hit.createdAt else { return "- \(hit.content)" }
            return "- (learned \(MemoryRecency.phrase(from: createdAt, to: now))) \(hit.content)"
        }.joined(separator: "\n")
        // The conflict clause is part of Tier 1: gemma-4-12B read the dated
        // pair and HEDGED ("either Ardmore or Dublin") until told how to break
        // ties; Qwen resolved on dates alone (memblock probe, 2026-07-30).
        return "WHAT I KNOW ABOUT YOU (remembered from past conversations — "
            + "use naturally, do not cite; where facts conflict, trust the most "
            + "recently learned):\n\(facts)"
    }

    /// The generative carve-out — the FIRST rule in BOTH prompt styles, shared
    /// verbatim so the wording can't drift between them (109 review nit; a
    /// pin test asserts both rendered prompts carry this exact text).
    static let generativeCarveOut =
        "- A request to write, create, code, or compose something is a task to "
            + "DO, not a lookup — just produce it. No tools, no grounding, no citations, "
            + "no \"found nothing\"; those are for factual questions."

    /// The carve-out when the "hands" (propose_script) are in the palette: still
    /// "just produce it", but a runnable SCRIPT routes to propose_script — a
    /// one-click review-and-install — instead of a code block the user has to
    /// save and chmod. Without this, the plain carve-out above ("just produce
    /// it. No tools") steers the model to PASTE the script and never call the
    /// tool (observed live 2026-08-23, the whole reason the hands looked inert
    /// even with the toggle on). Selected in `groundingBody`; a pin asserts
    /// both styles carry it verbatim when propose_script is offered.
    static let generativeCarveOutWithScripts =
        "- A request to write, create, code, or compose something is a task to "
            + "DO, not a lookup — just produce it. No grounding, no citations, no "
            + "\"found nothing\", and no tools — with ONE exception: when the user asks "
            + "you to write, create, or make a SCRIPT you could run on "
            + "\(HostPlatform.thisDevice), call propose_script with the full source "
            + "(a one-click review-and-install) instead of pasting it in a code block. "
            + "Everything else generative — poems, stories, code snippets — is still "
            + "produced directly, no web_search, no lookup_fact."

    /// open_link SHOWS; fetch_page READS — and a page is described only from what
    /// a tool returned. Added 2026-09-04 after Lil, holding a bare "Opened host"
    /// observation, narrated a page it never read (Kev's dislike). Offered-only,
    /// like every routing line (a pin test asserts presence/absence).
    static let openLinkRouting =
        "- open_link shows a page beside the chat and returns a short brief of it; to "
            + "READ a page in full, use fetch_page. Describe a page only from what a tool "
            + "returned — if the brief says the page could not be read, say so instead of "
            + "describing it."

    private static func groundingBody(
        chunks: [ChunkHit], memories: [ChunkHit], toolNames: Set<String>, style: PromptStyle,
        now: Date
    ) -> String {
        let hasWebSearch = toolNames.contains("web_search")
        // Every routing line names only tools actually offered THIS turn —
        // the self-query gate withholds search_knowledge, and a rule that
        // advertises an uncallable tool invites a doomed dispatch attempt.
        let hasSearchKnowledge = toolNames.contains("search_knowledge")
        var routing = switch (hasWebSearch, hasSearchKnowledge) {
        case (true, true):
            "- For current or external information — weather, news, prices, "
                + "anything happening now — use web_search. search_knowledge only "
                + "finds documents already stored on \(HostPlatform.thisDevice)."
        case (true, false):
            "- For current or external information — weather, news, prices, "
                + "anything happening now — use web_search."
        case (false, true):
            "- search_knowledge only finds documents already stored on "
                + "\(HostPlatform.thisDevice). You have no web access — if the stored knowledge can't "
                + "answer, say so plainly; do not guess."
        case (false, false):
            "- You have no web access — if you don't know, say so plainly; "
                + "do not guess."
        }
        if hasWebSearch, toolNames.contains("fetch_page") {
            routing += "\n- web_search returns snippets AND automatically reads the "
                + "top result's page for you. Use fetch_page only to read a "
                + "DIFFERENT result in full, then conclude from the page text."
        }
        if toolNames.contains("open_link") {
            routing += "\n" + Self.openLinkRouting
        }
        if toolNames.contains("lookup_fact") {
            routing += "\n- Stable, well-known facts (who wrote a famous book, a "
                + "capital city, basic science) you can just answer from what you know "
                + "— you're reliable there. Use lookup_fact only when you're genuinely "
                + "unsure, the detail is obscure or easy to mix up, or it could have "
                + "changed over time; then cite its Source."
        }
        // The hands reshape the generative carve-out: a runnable script routes
        // to propose_script, not a pasted code block (2026-08-23 live fix).
        let carveOut = toolNames.contains("propose_script")
            ? Self.generativeCarveOutWithScripts
            : Self.generativeCarveOut
        let rules = switch style {
        case .react:
            """
            RULES:
            \(carveOut)
            - Pure small talk — greetings, banter — needs no tools or knowledge: \
            reply IMMEDIATELY starting with "CONCLUSION:". A question about the \
            current world is NOT small talk, even phrased casually.
            - If the KNOWLEDGE already answers the question, reply IMMEDIATELY \
            starting with "CONCLUSION:" — do not use tools.
            - Cite knowledge sources inline with citation tokens like \
            [Title §heading]; never invent citations.
            - Never present a fact, figure, or date you can't ground or verify \
            as certain; if you're unsure, say so plainly. Honesty beats a confident guess.
            - If a search or lookup comes back empty or fails, answer with explicit \
            uncertainty — name what you couldn't confirm — rather than presenting a guess as fact.
            - Use at most two tool calls, never repeating one with the same argument.
            - Questions about yourself — your configuration, design, or abilities — \
            are answered from your persona; never search stored documents for them.
            \(routing)
            """
        case .native:
            """
            RULES:
            \(carveOut)
            - Pure small talk — greetings, banter — needs no tools or knowledge; just reply. \
            A question about the current world is NOT small talk, even phrased casually.
            - If the KNOWLEDGE above answers the question, answer from it directly.
            - Cite knowledge sources inline with citation tokens like \
            [Title §heading]; never invent citations.
            - Never present a fact, figure, or date you can't ground or verify \
            as certain; if you're unsure, say so plainly. Honesty beats a confident guess.
            - If a search or lookup comes back empty or fails, answer with explicit \
            uncertainty — name what you couldn't confirm — rather than presenting a guess as fact.
            - Never repeat a tool call with the same argument.
            - Questions about yourself — your configuration, design, or abilities — \
            are answered from your persona; never search stored documents for them.
            \(routing)
            """
        }
        let head: String
        if chunks.isEmpty {
            head = toolNames.contains("search_knowledge")
                ? "No stored knowledge was injected — the user's documents are "
                + "NOT in this context. If the question could concern their "
                + "stored documents, calls, or notes, call search_knowledge; "
                + "otherwise answer from what you genuinely know — and if you "
                + "don't, say so plainly rather than guessing."
                : "No stored knowledge matched this question."
        } else {
            let knowledge = chunks.enumerated().map { index, hit in
                "\(index + 1). \(ChatPromptBuilder.citationLabel(for: hit))\n\(hit.content)"
            }.joined(separator: "\n\n")
            // The hedge is deliberate and it is the cheap half of the fix for a
            // real failure (2026-08-12): asked what he had for dinner on 3 March,
            // M1K3 retrieved a fragment of a SCREENPLAY the user had stored and
            // narrated it — "a pomegranate being worked on by the High Priestess"
            // — before correctly saying it didn't know. Retrieval returns the
            // least-bad match for any question, so the head must not present it as
            // material the question is about. The empty branch above already tells
            // the model to say so plainly; this tells it these excerpts may have
            // nothing to do with the question at all.
            head = "KNOWLEDGE (excerpts from the user's own documents, calls and "
                + "notes, retrieved by similarity — they may be irrelevant to this "
                + "question; use only what genuinely answers it, and ignore the "
                + "rest rather than working it into the answer):\n\(knowledge)"
        }
        return [head, memoryBlock(memories, now: now), rules]
            .compactMap { $0 }
            .joined(separator: "\n\n")
    }
}
