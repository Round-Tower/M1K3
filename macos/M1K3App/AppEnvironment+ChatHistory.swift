//
//  AppEnvironment+ChatHistory.swift
//  M1K3App
//
//  Chat wiring kept out of AppEnvironment.swift because that file sits at the
//  1000-line file-length lint ceiling (the established split pattern: VoiceMode,
//  MCP, ChatHistory): the conversation-history store factory AND the tool-calling
//  chat-responder factory.
//
//  Signed: Kev + claude-fable-5, 2026-06-11, Confidence 0.9 (store + migrator
//  behaviour test-pinned in M1K3Chat; this is wiring). Prior: Unknown.
//  Review: Kev + claude-opus-4-8, 2026-06-12 — relocated makeAgentResponder here
//  (it pushed AppEnvironment past 1000) + added forcedThinkingMode for MCP fast-ask.
//

import Foundation
import M1K3Agent
import M1K3AgentTools
import M1K3Chat
import M1K3Inference
import M1K3Knowledge
import M1K3KnowledgeTools
import M1K3LanguageModel
import os
import Synchronization

extension AppEnvironment {
    private static let routeLog = Logger(subsystem: "app.m1k3", category: "route")
    /// Reused across sends so a turn doesn't allocate a fresh probe each time; the
    /// live `isAvailable` read (SystemLanguageModel.availability) stays per-call so a
    /// mid-session Apple-Intelligence change is honoured.
    private static let afmAvailabilityProbe = AppleFoundationModelsProvider()

    /// Apple Foundation Models availability in product terms — HelloView's
    /// FirstRunBrainPolicy input. Lives here (not on the class body) because the
    /// probe is file-private to this extension. Live read per call, same as the
    /// auto-route path above.
    var afmAvailability: AFMAvailability {
        Self.afmAvailabilityProbe.availabilityState
    }

    /// Apply the EscalationLadder's brain choice when auto-routing is on (ADR 0001).
    /// A NO-OP when off, so default behaviour is unchanged and the feature is fully
    /// reversible. Reuses `selectBrain`, so the routed pick drives the same proven
    /// load/warmup path; only switches when the pick actually changes.
    func applyAutoRouteIfEnabled() {
        guard UserDefaults.standard.bool(forKey: Self.autoRouteBrainKey) else { return }
        let tier = resolvedAutoRouteTier()
        // The directed-fetch guard (review catch, PR #154): "Let M1K3 choose"
        // with a not-yet-downloaded resolution stages a BACKGROUND fetch and
        // keeps the resident brain serving. Without this guard the very next
        // turn would selectBrain(tier) — cancelling that fetch and yanking the
        // user onto the blocking download path the feature exists to avoid.
        // The staged swap completes through attemptAutoSwapIfStaged, which
        // clears directedBrainTarget; from then on tier == selectedBrain.
        guard tier != selectedBrain, tier != directedBrainTarget else { return }
        Self.routeLog.info("auto-route → \(tier.rawValue, privacy: .public)")
        selectBrain(tier)
    }

    /// The brain auto-route resolves to for THIS Mac right now, given current
    /// Apple-Intelligence availability and consent settings (ADR 0001). Pure read —
    /// no side effects — so both `applyAutoRouteIfEnabled` and onboarding's
    /// "Let M1K3 choose" can ask "what would auto-route pick?" without committing.
    func resolvedAutoRouteTier() -> BrainTier {
        let defaults = UserDefaults.standard
        // Phase 17a (resolves the old Edge-A placeholder): the ladder's egress gate reads
        // its own DEDICATED default-OFF consent key — never the web-search toggle,
        // which defaults ON and governs web TOOLS (a different egress category).
        // No UI writes this yet by design; the consent surface ships WITH the PCC
        // rung (17b) so no dead control reaches macOS 26 builds.
        let egressAllowed = ChatEgressConsent.networkAllowed(
            persisted: defaults.object(forKey: ChatEgressConsent.defaultsKey) as? Bool
        )
        // "Prefer Apple on-device" was cut from Settings (2026-07-13, Kev-approved):
        // auto-route always prefers M1K3's own tuned model — stronger at open chat —
        // over Apple's on-device model. Always false, not read from a dead control.
        let route = M1K3BrainRouter.route(
            appleIntelligenceAvailable: Self.afmAvailabilityProbe.isAvailable,
            networkAllowed: egressAllowed,
            preferAppleOnDevice: false
        )

        let routedTier: BrainTier
        switch route {
        case .appleOnDevice:
            routedTier = .mini
        case .mlxFloor, .privateCloud, .thirdParty:
            // No network-brain backends are wired yet, so those rungs resolve to the
            // local MLX floor: keep the current MLX brain, else default to Lil.
            routedTier = selectedBrain.mlxModelID != nil ? selectedBrain : .lil
        }
        // Prudent compute: ease the automatic pick down to what THIS Mac can run
        // comfortably (lower-only — never a silent upgrade-download). This is what
        // makes auto-route machine-aware: Big has no hard memory floor, so without
        // the cap it would otherwise ride along on a small Mac and thrash swap.
        // Manual selection stays sovereign (capped only on the AUTOMATIC path).
        return BrainTier.cappedForThisMac(routedTier)
    }

    /// Onboarding "Let M1K3 choose": turn auto-route ON and resolve the concrete
    /// starting brain so the first-run flow can drive the SAME download/wake UI a
    /// manual pick uses. Returns the resolved tier plus whether it was already
    /// loaded (selectBrain's no-op — the caller must advance itself; no
    /// modelLoad transition is coming).
    @discardableResult
    func enableAutoRouteForOnboarding() -> (tier: BrainTier, alreadyAwake: Bool) {
        UserDefaults.standard.set(true, forKey: Self.autoRouteBrainKey)
        let tier = resolvedAutoRouteTier()
        let alreadyAwake = selectBrain(tier)
        return (tier, alreadyAwake)
    }

    /// Memory auto-capture consent (Settings "Learn from conversations").
    /// Default ON: everything is local, every memory visible and deletable
    /// in MemoriesView — the webSearchEnabledKey default-true read pattern.
    nonisolated static let memoryAutoCaptureKey = "memoryAutoCapture"

    nonisolated static func memoryAutoCaptureEnabled() -> Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: memoryAutoCaptureKey) == nil
            || defaults.bool(forKey: memoryAutoCaptureKey)
    }

    /// The distillation stack: AFM-first under NEUTRAL instructions (the
    /// distiller must not speak as M1K3 — judge-not-the-defendant), falling
    /// back to the shared runtime provider. The fallback path carries the
    /// persona (a second MLX instance would double model memory); the
    /// FACT:-only parser is the defence there.
    nonisolated static func makeMemoryDistillation(
        store: KnowledgeStore,
        embedder: any EmbeddingService,
        ingester: DocumentIngester,
        fallback: any InferenceProvider,
        graph: (any DistilledFactGraphWriting)? = nil
    ) -> MemoryDistillationCoordinator {
        MemoryDistillationCoordinator(
            distiller: ProviderMemoryDistiller(
                primary: AppleFoundationModelsProvider(
                    instructions: { MemoryDistillationPrompt.instructions }
                ),
                fallback: fallback
            ),
            ingester: ingester,
            store: store,
            embedder: embedder,
            graph: graph
        )
    }

    /// Build the conversation store and run the one-shot legacy-transcript
    /// migration BEFORE ChatSession init reads it (resume-most-recent must see
    /// the import). nil on store failure → chat degrades to non-persistent,
    /// exactly like the old optional transcript.
    static func makeChatHistoryStore(in dir: URL) -> (any ChatHistoryPersisting)? {
        guard let store = try? GRDBChatHistoryStore(
            path: dir.appendingPathComponent("chat-history.sqlite").path
        ) else { return nil }
        try? TranscriptMigrator.migrateIfNeeded(
            legacyURL: dir.appendingPathComponent("transcript.json"),
            into: store
        )
        return store
    }

    /// The interactive agent tool LIST — one builder shared by the responder's
    /// per-turn `toolsProvider` and the persona-prefix warm, so the warmed
    /// (persona × tools) cache key can never drift from what the live turn
    /// renders. The warm passes no-op callbacks: only the tool DEFINITIONS
    /// (names, descriptions, schemas) reach the prefix; callbacks never render.
    nonisolated static func interactiveAgentTools(
        store: KnowledgeStore,
        embedder: any EmbeddingService,
        onHits: @escaping @Sendable ([ChunkHit]) -> Void,
        onOpenLink: (@Sendable (URL) -> Void)?,
        deepDelegation: DeepDelegationHook? = nil,
        scriptExecution: ScriptExecutionHook? = nil
    ) -> [any AgentTool] {
        var tools: [any AgentTool] = [
            DateTimeTool(),
            SystemStatusTool(),
            SearchKnowledgeTool(store: store, embedder: embedder, onHits: onHits),
            ListDocumentsTool(store: store),
            GetDocumentTool(store: store),
        ]
        // delegate_deep joins ONLY the interactive-chat palette (non-nil hook is
        // passed solely by the main responder): MCP's ask_m1k3 has its own job
        // model and must not spawn background MLX work, the menu-bar Ask is a
        // one-shot, and the delegation lane's own deep responder must never
        // recurse into another delegate_deep.
        if let deepDelegation {
            tools.append(DelegateDeepTool(startDelegation: { task in
                await deepDelegation.invoke(task)
            }))
        }
        let defaults = UserDefaults.standard
        let webAllowed = defaults.object(forKey: Self.webSearchEnabledKey) == nil
            || defaults.bool(forKey: Self.webSearchEnabledKey)
        if webAllowed {
            tools.insert(WikipediaTool(), at: 0)
            tools.insert(FetchPageTool(), at: 0)
            // Deterministic search→read: small models won't chain to
            // fetch_page themselves, so web_search auto-reads the top
            // result and feeds real page text back in one observation.
            // The deep reader uses a tight, no-retry fetch (8s) so a slow
            // or JS-only top result bails fast instead of blowing the turn
            // budget. (fetch_page — default 12s+retry — stays available for
            // the model to read OTHER results in full.)
            let deepReader = FetchPageTool(fetcher: URLSessionHTTPFetcher(timeout: 8))
            tools.insert(WebSearchTool(deepReader: deepReader), at: 0)
        }
        if let onOpenLink {
            tools.append(OpenLinkTool(onOpen: onOpenLink))
        }
        // The hands (context-tools charter): interactive chat ONLY (non-nil
        // hook comes solely from the main responder + its warm), and only
        // while the default-OFF Settings toggle is on — off means the tools
        // are ABSENT from the palette, not refused (charter rule 1). MCP's
        // LAN scope additionally fails closed (not in lanAllowedTools).
        if let scriptExecution, defaults.bool(forKey: Self.scriptToolsEnabledKey) {
            tools.append(ExecuteScriptTool(
                runner: scriptExecution.runner, approvals: scriptExecution.approvals
            ))
            tools.append(ProposeScriptTool(onPropose: scriptExecution.onPropose))
        }
        return tools
    }

    /// The tool-calling chat responder: every turn runs the agent loop with
    /// retrieve-first grounding, plus web search / datetime / system status /
    /// a second knowledge lookup as tools. The tool list is built fresh each
    /// turn so the Settings web-search toggle applies immediately — disabled
    /// means the model never even sees the tool.
    /// `forcedThinkingMode` pins the reasoning budget regardless of Settings —
    /// the MCP `ask_m1k3` path passes `.fast`. ask_m1k3 is a grounding tool for
    /// a visiting agent ("find and cite my private corpus"), not a synthesis
    /// engine: on these small local brains the think phase is what blows past
    /// the deadline on anything but a lookup (test-report follow-up, 2026-06-12).
    /// nil keeps the Settings picker + voice-mode override (the chat/voice UI).
    /// `onOpenLink`, when supplied, adds the `open_link` agent tool so the model
    /// can surface a web page into the review panel mid-answer. Only the
    /// interactive chat responder passes it — the MCP/ask responder (forced
    /// `.fast`, headless) has no panel to drive.
    nonisolated static func makeAgentResponder(
        store: KnowledgeStore,
        embedder: any EmbeddingService,
        provider: any InferenceProvider,
        forcedThinkingMode: ThinkingMode? = nil,
        onOpenLink: (@Sendable (URL) -> Void)? = nil,
        deepDelegation: DeepDelegationHook? = nil,
        scriptExecution: ScriptExecutionHook? = nil
    ) -> any RAGResponding {
        // Hits the model retrieves itself (search_knowledge) flow through the
        // collector into the turn's sources + the citation allow-list.
        let sourceCollector = ToolSourceCollector()
        return AgentRAGResponder(
            store: store,
            embedder: embedder,
            provider: provider,
            toolsProvider: {
                Self.interactiveAgentTools(
                    store: store,
                    embedder: embedder,
                    onHits: { hits in sourceCollector.record(hits) },
                    onOpenLink: onOpenLink,
                    deepDelegation: deepDelegation,
                    scriptExecution: scriptExecution
                )
            },
            sourceCollector: sourceCollector,
            thinkingModeProvider: {
                // A forced mode (MCP ask_m1k3 → .fast) bypasses Settings entirely.
                if let forcedThinkingMode { return forcedThinkingMode }
                let defaults = UserDefaults.standard
                let stored = defaults.string(forKey: Self.thinkingModeKey)
                    .flatMap(ThinkingMode.init(rawValue:)) ?? .auto
                // Voice mode swaps Settings for its own in-mode toggle
                // (default off → fast; read per turn, so flips apply next turn).
                return VoiceThinkingPolicy.effectiveMode(
                    stored: stored,
                    voiceModeActive: defaults.bool(forKey: Self.voiceModeActiveKey),
                    voiceThinkingEnabled: defaults.bool(forKey: Self.voiceModeThinkingKey)
                )
            },
            brainNameProvider: {
                // The persisted brain tier, read fresh each turn so a runtime
                // hot-swap names the new brain on the next answer. Empty → omitted.
                let raw = UserDefaults.standard.string(forKey: Self.selectedBrainKey) ?? ""
                return BrainTier(persisted: raw)?.displayName ?? ""
            },
            fastThinkingProvider: {
                // Speed tiers (Mini/Lil) skip the think phase on plain grounded
                // lookups — read fresh each turn so a hot-swap applies immediately.
                let raw = UserDefaults.standard.string(forKey: Self.selectedBrainKey) ?? ""
                return BrainTier(persisted: raw)?.prefersFastThinking ?? false
            },
            historyBudgetProvider: {
                // Brain-aware long context: a wide conversation replay on the
                // dense-Qwen lil (~32K window), a hard clamp on gemma-4
                // (big, whose RotatingKVCache silently rotates the persona/grounding
                // head out past 8192). Read fresh each turn so a hot-swap re-sizes
                // the window immediately. Mini (Apple Foundation Models) manages its
                // own window — keep the conservative shipped default there (its real
                // budget is the named [SPIKE]; don't risk an AFM overflow error).
                let raw = UserDefaults.standard.string(forKey: Self.selectedBrainKey) ?? ""
                // The mini/unknown → conservative-replay guard lives in the
                // policy's optional-tier overload, not here (unit-pinned there).
                return HistoryBudgetPolicy.budget(
                    for: BrainTier(persisted: raw),
                    reservedTokens: Self.historyReserveTokens,
                    generationTokens: Self.historyGenerationReserveTokens
                )
            },
            maxIterationsProvider: {
                // Prudent Compute is ALWAYS ON (2026-07-13, Kev-approved — was an
                // opt-in toggle): CoolHeadPolicy trims the agent loop to the LIVE
                // thermal level (read fresh each turn from the shared state — never
                // snapshotted; the responder is built once and long-lived). The
                // brain is NEVER swapped (CoolHeadPolicy doctrine: ease effort,
                // not identity). At `.full` (the common case) this is byte-identical
                // to the old default-OFF path.
                CoolHeadPolicy.maxIterations(
                    for: Self.coolHead.withLock(\.level),
                    base: Self.baseMaxIterations
                )
            },
            defersHeavyGenerationProvider: {
                // Same always-on doctrine as the iteration cap above. Only bites at
                // `.minimal` (critical thermal / low-power) — the turn skips the
                // heavy retrieve+generate and answers with an honest deferral.
                // Level is the LIVE thermal state advanced by applyCoolHead() at the
                // top of THIS send().
                CoolHeadPolicy.defersHeavyGeneration(Self.coolHead.withLock(\.level))
            },
            groundingBudgetProvider: {
                // Grounding sized to the brain, for the same reason the replay
                // above is. `GroundingBudget.defaultTokenBudget` (1100) was DERIVED
                // from BIG's 3000-token reserve inside an 8192-token window; handing
                // that same figure to Mini spends 27% of everything it has and
                // starves the answer. Read fresh each turn so a hot-swap re-sizes
                // immediately; the mini/unknown guard lives in the policy, pinned
                // there rather than re-implemented in app glue.
                //
                // A SPOKEN turn is tighter again. Prefill is paid in full before
                // the first token exists and voice mode speaks at the first
                // sentence, so grounding tokens land directly on
                // time-to-first-audio at a measured 1.71 ms each (Lil, live path,
                // 2026-08-13). The mode is read from the same nonisolated
                // UserDefaults flag voice mode already maintains — this closure
                // is @Sendable and cannot touch the main-actor `voiceLoop`.
                let defaults = UserDefaults.standard
                let raw = defaults.string(forKey: Self.selectedBrainKey) ?? ""
                return GroundingBudgetPolicy.tokens(
                    for: BrainTier(persisted: raw),
                    spoken: defaults.bool(forKey: Self.voiceModeActiveKey)
                )
            }
        )
    }

    // MARK: - Cool Head (thermal effort easing — ADR: never swaps the brain)

    // Prudent Compute (2026-07-13, Kev-approved): ALWAYS ON — was an opt-in
    // Settings toggle ("Ease off when my Mac runs hot"), now standing behaviour.
    // Eases M1K3's EFFORT when the Mac is under thermal / low-power pressure
    // (trims the agent loop); at `.full` (the common case) the effect is
    // byte-identical to the old default-OFF path. It deliberately never swaps
    // the chosen brain — a mid-conversation reload would dump the KV + persona
    // caches and rename M1K3's own identity for the sake of the room temperature
    // (CoolHeadPolicy's signed reasoning).

    /// Whether speculative/background work — the launch reindex, the embedder
    /// pre-warm, the constellation poll cadence — should run right now.
    ///
    /// ALWAYS-ON since the 2026-07-13 cut (was behind the cool-head opt-in, so
    /// this gate was a no-op for default users): serious/critical heat OR Low
    /// Power Mode now defers background work for everyone. Every deferring call
    /// site arms `armThermalRecovery()`, which watches BOTH the thermal AND the
    /// power-state notifications — a Mac on battery-saver recovers its deferred
    /// work the moment Low Power Mode lifts, not at the next relaunch.
    ///
    /// Reads `ProcessInfo` DIRECTLY, not the chat-turn `coolHead.level`: that level
    /// is only advanced by `applyCoolHead()` on a `send()`, so at launch
    /// and window-open seams (which fire outside any turn) it is stale/default
    /// `.full` — gating background work on it would be a silent no-op. Point-in-time
    /// (`target`, no hysteresis): a background check is one-shot, not a conversation
    /// to keep from flapping.
    nonisolated static func backgroundWorkAllowed() -> Bool {
        let info = ProcessInfo.processInfo
        let level = CoolHeadPolicy.target(
            thermal: info.thermalState, lowPower: info.isLowPowerModeEnabled
        )
        return CoolHeadPolicy.allowsBackgroundWork(level)
    }

    /// The agent-loop iteration base the thermal cap eases DOWN from. Matches
    /// AgentRAGResponder's default — one named home so the two can't drift.
    nonisolated static let baseMaxIterations = 3

    /// Conservative fixed reserve (tokens) for the NON-history parts of the prompt
    /// — persona+exemplars (~1130) + tools spec (~600) + grounding chunks (~1100)
    /// + goal/context line (~170). Subtracted from the tier's window before the
    /// conversation replay gets what's left. Bigger = safer (less history, less
    /// chance of crossing gemma's 8192). Tune from the `ttft` token-count log
    /// (the [SPIKE]) — this is a verify-by-launch estimate, not a measured fact.
    nonisolated static let historyReserveTokens = 3000

    /// Generation headroom (tokens) kept clear of a rotating-KV window so a normal
    /// answer can't rotate gemma's persona/grounding head out mid-decode. 2048 is
    /// generous for these brains' typical answers; a pathologically long gemma
    /// answer at a full history budget is the residual verify-owed (SelfTest step).
    nonisolated static let historyGenerationReserveTokens = 2048

    /// Turns of SUSTAINED relief required before effort recovers (hysteresis) —
    /// degrade now, recover slow, so a bouncing thermalState can't flap the level.
    nonisolated static let coolHeadMinRecoveryTurns = 3

    /// Process-wide thermal state with recovery hysteresis (CoolHeadPolicy.next).
    /// Static because there is exactly one AppEnvironment, and the `nonisolated
    /// static` responder factory must read the live level without capturing `self`.
    nonisolated static let coolHead = Mutex(CoolHeadState())

    /// Advance the thermal state for this turn — degrade immediately, recover only
    /// after a sustained relief streak (hysteresis, so a bouncing thermalState can't
    /// flap the effort level). Called beside `applyAutoRouteIfEnabled` at the top
    /// of `send`, so the level is current for the SAME turn's
    /// `maxIterationsProvider` read. Always runs — Prudent Compute is standing
    /// behaviour, not opt-in (2026-07-13).
    func applyCoolHead() {
        let info = ProcessInfo.processInfo
        let target = CoolHeadPolicy.target(
            thermal: info.thermalState,
            lowPower: info.isLowPowerModeEnabled
        )
        Self.coolHead.withLock { state in
            state = CoolHeadPolicy.next(
                state, target: target, minRecoveryTurns: Self.coolHeadMinRecoveryTurns
            )
        }
    }
}
