//
//  AppEnvironment.swift
//  M1K3App
//
//  The composition root: wires the pure package brain into one object the SwiftUI
//  views observe. Everything here is a thin assembly of types that are already
//  tested in the package — no business logic lives in the app target.
//
//  Sandbox note: the KnowledgeStore is opened under Application Support, which the
//  App Sandbox redirects into the app container. This is the path the unit tests
//  (in-memory) can't exercise, so it's pinned explicitly here.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.8, Prior: Unknown
//
//  Review: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.8 — selecting MLX
//  Gemma now preloads the weights (`preloadGemma`) and folds download progress
//  into the observable `modelLoad: ModelLoadState`, mirroring the existing
//  embeddings-switch pattern; the embedder switch routes its own download % into
//  `embeddingStatus`. Fixed the "Gemma 4" runtime labels (Gemma 3 is current).
//  Review: Kev + claude-fable-5, 2026-06-11 — speech wiring moved to
//  wireSpeechCallbacks() (+ word-timing → SpeechHighlight); voiceLoop stored
//  property + speechDidEnd routing; voice-mode Auto→fast thinking override;
//  stale voiceMode.active cleared at launch. Confidence 0.8.
//  Review: Kev + claude-opus-4-8, 2026-06-17, Confidence 0.85 — added the shared
//  intelligence surface's stored state: `intelligenceResponder` (one lazy,
//  brain-switch-tracking RAGResponder) + `intelligenceAskInFlight` (one
//  single-flight lock), both shared by the MCP `ask_m1k3` tool AND the new Ask App
//  Intent (logic in AppEnvironment+Intelligence.swift). Additive; existing wiring
//  unchanged.

import AppKit
import Foundation
import M1K3Agent
import M1K3AgentTools
import M1K3Avatar
import M1K3Calls
import M1K3Chat
import M1K3Heartbeat
import M1K3Inference
import M1K3Knowledge
import M1K3KnowledgeTools
import M1K3Kokoro
import M1K3MCPLog
import M1K3Memory
import M1K3MemoryChatBridge
import M1K3MLX
import M1K3Preview
import M1K3Voice
import M1K3WhisperKit
import Network
import Observation
import os

/// The two inference backends a brain can route to. A routing key, not a
/// user-facing picker — the brain tiers (Mini/Lil/Big) are the vocabulary
/// users see. (The old runtime-picker surface, its LiteRT reserved slot, and
/// its subtitle/icon decoration were removed in the 2026-08-03 reduction
/// wave: the picker UI died when brains replaced it, and LiteRT was dropped
/// without ever being built — see PLAN.md.)
/// Brain-selection trail (the one-time front-tier realignment). `mlx-load` is the
/// registered category for which brain is in the slot and why.
private let frontTierLog = Logger(subsystem: "app.m1k3", category: "mlx-load")

enum RuntimeOption: String {
    case appleFoundationModels = "Apple Foundation Models"
    /// Model-neutral label: the MLX slot now serves whichever brain is chosen
    /// (Qwen3 Lil, Gemma 4 Big) — not display-persisted, safe to rename.
    case mlxGemma = "MLX (local model)"
}

@MainActor
@Observable
final class AppEnvironment {
    let store: KnowledgeStore
    /// The temporal memory GRAPH — atomic facts + typed edges, SEPARATE from the
    /// RAG document corpus (`store`). The MCP `remember` dual-writes here; the
    /// recall_memory/related_memory tools read it. Best-effort: a MemoryStore
    /// hiccup never breaks the existing KnowledgeStore remember path.
    let memoryStore: MemoryStore?
    /// The Agent Interaction Log: an MCPCallLogSink that persists every MCP
    /// tool call's request + response when the user opts in (Settings toggle,
    /// OFF by default). Wired into `MCPHostController.start()` as the
    /// registry's log sink; self-gates live on `conversationLogEnabledKey`, so
    /// flipping the toggle takes effect with no server restart. Best-effort,
    /// same inert-on-open-failure stance as `memoryStore`.
    let conversationLog: ConversationLogStore?
    /// The heartbeat's pulse store (heartbeat.sqlite, capped rolling window,
    /// one-tap Clear, excluded from diagnostics AND from the chat transcript
    /// — so memory distillation can never mint facts from a pulse). Gated by
    /// `heartbeatEnabledKey` (OFF by default); best-effort, same
    /// inert-on-open-failure stance as `memoryStore`.
    let heartbeatStore: HeartbeatStore?
    let provider: any InferenceProvider
    let responder: any RAGResponding
    /// The review panel's shared state: the inspector, chat link-chips, the MCP
    /// `open_link` tool, and the local agent all converge here. Default-initialised
    /// (no deps) so it's available to capture while the rest of init runs.
    let review = ReviewModel()
    /// TTS behind a swappable seam: Built-in (Apple) by default, M1K3 Voice
    /// (Kokoro) once downloaded. Callers never see the swap.
    let speech: SwappableSpeechProvider
    let chat: ChatSession

    let embedder: SwappableEmbeddingService // internal: MCPHostController builds a dedicated responder
    let ingester: DocumentIngester // internal: the MCP remember tool ingests through it
    /// The intelligence surfaces (MCP `ask_m1k3` AND the Ask App Intent) share ONE
    /// dedicated responder and ONE single-flight lock: `collectedSources()` is a
    /// draining read, so two asks on the same provider must never overlap. Built
    /// lazily on first ask; `provider` is the swappable runtime façade, so brain
    /// switches track without a rebuild. `.fast` thinking — the synthesis think
    /// phase is what blew past the deadline on small local brains; the chat window
    /// is where the fuller answer lives. (See AppEnvironment+Intelligence.swift.)
    @ObservationIgnored private(set) lazy var intelligenceResponder: any RAGResponding =
        Self.makeAgentResponder(
            store: store, embedder: embedder, provider: provider, forcedThinkingMode: .fast
        )
    /// True while an `ask_m1k3` / Ask-intent generation is running (shared lock).
    /// Observation is intentionally suppressed: the VISIBLE "answering" signal is
    /// carried by the avatar activity (which IS observable); this Bool is read by
    /// the MCP status poll, so re-triggering SwiftUI on every flip would be noise.
    @ObservationIgnored var intelligenceAskInFlight = false
    private let runtimeSelection: RuntimeSelectionBox
    /// The interim-Mini bridge: non-nil (.appleFoundationModels) while the
    /// selected weight-backed brain is still loading AND AFM can serve, so
    /// turns route to Mini without touching `selectedRuntime` or the persisted
    /// brain. Kept in sync by `refreshInterimBridge()` from `modelLoad`/
    /// `selectedRuntime`'s didSets — the box is read lock-side at generate
    /// time, so it can't be a computed property here.
    private let interimRuntimeOverride = RuntimeOverrideBox()
    /// AFM availability CACHED for the gate (stored HERE — extensions can't
    /// hold stored properties). The live probe
    /// (`SystemLanguageModel.default.availability`) does real Security-
    /// framework IPC — the unified log flags it as main-thread-unsafe — and
    /// `chatGate` is evaluated on every download-progress tick. Worse than the
    /// cost: a probe that wobbles `.available` ↔ `.notReady` under load makes
    /// the gate OSCILLATE `.interim` ↔ `.blocked`, mounting/unmounting the
    /// full ModelGateView per tick — the leading theory for the 07-25
    /// NSGenericException layout crashes. Availability only genuinely changes
    /// when the user flips Apple Intelligence in System Settings, so a
    /// per-launch snapshot (invalidated on brain switch, see `selectBrain`)
    /// is honest. First-run/onboarding flows keep their own live re-polls.
    @ObservationIgnored var cachedBridgeAFM: AFMAvailability?
    /// Last gate value the bridge saw — transition breadcrumbs only
    /// (`.notice` because `.info`/`.debug` don't persist in OSLogStore).
    @ObservationIgnored var lastBridgedGate: ChatGate?
    /// delegate_deep state (stored HERE — extensions can't hold stored
    /// properties; plain `var` because the writer lives in
    /// AppEnvironment+DeepDelegation.swift, the `weightImportState` precedent).
    /// nil = idle; non-nil = the task the deep lane is digging into.
    var deepDelegationTaskLabel: String?
    /// The in-flight delegated run — held (never cancelled by UI churn), the
    /// voice-loop turnTask rule: the answer must land even if the user wanders.
    @ObservationIgnored var deepDelegationTask: Task<Void, Never>?
    /// Late-bound bridge the delegate_deep tool holds (the palette is built in
    /// init before `self` exists); the handler installs at the end of init.
    let deepDelegationHook = DeepDelegationHook()
    /// Escalated-dive slot bookkeeping (2026-08-15, the DeepDiveTarget wiring):
    /// while a dive runs on Big, the resident brain's provider is parked in
    /// `deepDiveRestoreProvider` and the slot is restored from it on EVERY dive
    /// exit — `finishDeepDelegation` is the single teardown point for success
    /// and failure alike, so there is no path that leaves Big in the slot.
    @ObservationIgnored var deepDiveRestoreProvider: MLXGemmaProvider?
    /// The Big provider an escalated dive runs on — released at restore.
    @ObservationIgnored var deepDiveEscalatedProvider: MLXGemmaProvider?
    /// The heartbeat's coarse check loop (10-min ticks deciding via the pure
    /// policy) — see AppEnvironment+Heartbeat.swift.
    @ObservationIgnored var heartbeatTask: Task<Void, Never>?
    /// Bumped after each recorded pulse so SwiftUI surfaces re-read the store
    /// (the `historyRevision` idiom).
    var heartbeatRevision = 0
    /// The most recent hold (skip/withhold reason + when) — observable so the
    /// idle card and Heartbeat window can say WHY the pulse is stale instead
    /// of silently ageing. Cleared on every recorded pulse.
    var heartbeatLastHold: HeartbeatHold?
    /// Single-flight guard for one pulse's gather→render→record run.
    @ObservationIgnored var heartbeatPulseInFlight = false
    /// Call intelligence: encrypted-at-rest persistence + indexing into the SAME
    /// knowledge graph as documents (so calls are RAG-searchable) + two-stage
    /// summary. Composed from the M1K3Calls seams.
    private let callPersistence: any CallPersistence
    private let callIngester: CallIngester
    private let callSummarizer: SummarizationPipeline
    /// Recording is consent-gated (legal: call recording needs consent) and captured
    /// by the StereoCallRecorder below.
    private let consentGate = RecordingConsentGate(store: UserDefaultsConsentStore())
    /// Stereo capture: near-end mic + far-end system audio (ScreenCaptureKit),
    /// muxed so the diarizer can separate speakers. Degrades to mono mic if
    /// screen-recording permission is absent.
    private let recorder = StereoCallRecorder()
    /// Durable home for captured recordings (under Application Support, NOT the OS
    /// temp dir). A recording lives here until it's transcribed + saved, then it's
    /// removed — so a `.caf` left here at launch is a parked recording to recover.
    /// This is what survives a relaunch; the in-memory `lastRecordingURL` alone did
    /// not, and the temp dir could be swept (recordings vanished before they were
    /// ever transcribed).
    private let recordingsDir: URL
    /// The MLX provider for the currently-selected brain (Lil = Qwen / Big =
    /// Gemma). Rebuilt when the brain changes; held directly so the onboarding /
    /// picker can warm it and stream download progress to the UI.
    /// `private(set)`: written only in this file (selectBrain); READ by
    /// AppEnvironment+DeepDelegation to park the resident provider across an
    /// escalated dive's slot swap.
    private(set) var currentMLXProvider: MLXGemmaProvider
    /// "Is this brain's weights already on disk?" — drives the onboarding card's
    /// "On disk · ready" hint instead of dangling a download the user already did.
    private let brainInventory = LocalModelInventory()
    /// The single MLX slot behind `RuntimeOption.mlxGemma` in the façade; re-pointed
    /// at `currentMLXProvider` whenever the brain switches between Lil and Big, so
    /// the swap is seen without rebuilding the RAGResponder. Internal (not
    /// private) for AppEnvironment+DeepDelegation.swift — the delegation lane
    /// runs its responder DIRECTLY against this slot, bypassing the runtime
    /// façade's interim override (which is busy routing interactive turns to
    /// Mini while the slot digs).
    let swappableMLX: SwappableInferenceProvider
    /// Voice input: WhisperKit (high accuracy, needs a model) routed ahead of
    /// Apple Speech (system framework, always available). Held directly so the
    /// app can load WhisperKit's model on demand. Internal (not private) for
    /// AppEnvironment+VoiceMode.swift — the voice loop consumes the same
    /// recogniser seam (LocalAgent+Logging precedent).
    let transcription: TranscriptionRouter
    private let whisperKit: WhisperKitProvider
    private var dictationProvider: (any TranscriptionProvider)?
    private var dictationTask: Task<Void, Never>?
    /// Batch (file → segments) transcription for recorded calls. Closes the mic
    /// path: a stopped recording runs through the SAME CallIntelligencePipeline the
    /// import path proves. Opt-in (needs a model) like live WhisperKit.
    private let batchTranscriber: WhisperKitBatchTranscriber

    /// True while the mic is live. `liveTranscript` is the best-so-far text shown
    /// in the input bar as the user speaks.
    private(set) var isListening = false
    private(set) var liveTranscript = ""
    /// The M1K3 Voice earned-moment offer is live (set on leaving voice mode
    /// once VoiceUpgradeOfferPolicy says the user has genuinely heard the
    /// everyday voice). Drives the one-line banner; cleared on accept/dismiss.
    var voiceUpgradeOffered = false
    /// The user-intro earned moment is live (IntroductionOfferPolicy: a few
    /// real exchanges in, M1K3 doesn't know them yet, never asked before).
    /// Accepting just focuses the input — the intro is a conversation, not a
    /// form; memory auto-capture learns from whatever they say.
    var introductionOffered = false
    /// Set when a voice gesture hit a denied/restricted mic or speech grant —
    /// the silent-denial fix. Drives the recovery banner (which System Settings
    /// pane to open); cleared on dismiss or a later successful listen. Written
    /// by the pre-flight in enterVoiceMode/startDictation and the zero-segment
    /// backstop (AppEnvironment+VoiceMode).
    var voicePermissionRecovery: VoicePermissionPolicy.Recovery?
    /// WhisperKit model-load state — mirrors `modelLoad` for the brain tier.
    private(set) var whisperLoad: ModelLoadState = .idle
    private var isPreparingWhisper = false
    /// The active WhisperKit accuracy tier (drives the Settings picker). Restored
    /// in `init`; changing it persists + applies on next launch.
    private(set) var selectedWhisperModel: WhisperModelVariant = .defaultVariant

    /// Voice OUTPUT (TTS). The Built-in Apple voice is the swap-back target;
    /// Kokoro is the premium "M1K3 Voice" tier (downloads on first use).
    private let builtinSpeech: AVSpeechProvider
    private let kokoro: KokoroSpeechProvider
    /// "M1K3 Voice" model-load state — mirrors `whisperLoad`/`modelLoad`.
    private(set) var voiceLoad: ModelLoadState = .idle
    /// The chosen TTS tier; restored on launch, persisted on change.
    private(set) var selectedVoiceTier: VoiceTier = .builtin
    private var isPreparingVoice = false

    /// The avatar companion state — driven by this environment at each transition
    /// (listening → thinking → generating → speaking → idle).
    private(set) var avatar = AvatarController()
    /// UI earcons. Lazy so `isSpeaking` can read the live avatar state (an
    /// earcon must never step on M1K3's voice). Enabled from the persisted
    /// preference; the Settings toggle updates `isEnabled` live. Not observed —
    /// nothing in the UI reacts to the player object (lazy needs a stored prop,
    /// which @Observable's rewrite would otherwise forbid).
    @ObservationIgnored private(set) lazy var soundEffects: SoundEffectPlayer = .bundled(
        isEnabled: Self.soundEffectsEnabledDefault,
        volume: 0.4, // gentle — earcons are seasoning, not the meal (was 0.6 default)
        isSpeaking: { [weak self] in
            guard let self else { return false }
            if case .speaking = avatar.state.activity { return true }
            return false
        }
    )

    /// Word-highlight state for speech playback (the karaoke reading view).
    let speechHighlight = SpeechHighlight()
    /// Chat auto-speak session — the poller that speaks a streaming answer
    /// sentence-by-sentence while the transcript renders it. One at a time;
    /// a new send supersedes the old (AppEnvironment+AutoSpeak.swift).
    var autoSpeakTask: Task<Void, Never>?
    /// Voice-first mode's conversation loop — non-nil while the mode is active.
    /// Written ONLY by enterVoiceMode/exitVoiceMode (AppEnvironment+VoiceMode.swift;
    /// internal because private(set) is file-scoped).
    var voiceLoop: VoiceLoopController?
    /// In-process MCP server lifecycle + voice tool glue (MCPHostController.swift).
    /// Set once at init tail (needs self for the handler closures).
    private(set) var mcpHost: MCPHostController!
    /// Menu-bar "Ask M1K3" — a headless grounded answer with no chat window.
    /// Owns its own dedicated responder (MenuBarAsk.swift); set at init tail.
    private(set) var menuBarAsk: MenuBarAsk!

    /// Statics merged onto shared lines where sensible: the class body rides the
    /// type_body_length ceiling, and @Observable ignores statics (unlike stored
    /// instance vars, which CANNOT share a declaration line under the macro).
    private static let embedderPrefersMLXKey = "embedder.prefersMLX"
    /// `nonisolated` (like the sibling keys) so a @Sendable closure — the
    /// responder's per-turn brain-name lookup — can read it off the main actor.
    nonisolated static let selectedBrainKey = "selectedBrain"

    /// Marker for the one-time realignment of a persisted brain pick that the
    /// ladder no longer recommends (2026-08-11). Set on every evaluation of the
    /// nudge, fired or NOT — it records that the one-time window has passed, not
    /// that anything moved. Writing it only when it fires leaves a Mac that's
    /// already on the recommended tier eligible forever, and then takes back the
    /// first heavy tier its owner deliberately picks. See the contract on
    /// `FrontTierRealignment.plan`.
    nonisolated static let frontTierRealignedKey = "brain.frontTierRealigned"
    /// Whether the user has completed brain selection — gates the onboarding flow.
    static let hasChosenBrainKey = "hasChosenBrain"
    static let selectedVoiceTierKey = "selectedVoiceTier"
    /// Web search (DuckDuckGo) in chat — ON by default, visible in the activity
    /// label every time it fires, and switchable off in Settings (the tool is
    /// then never offered to the model). The one capability that sends
    /// chat-derived queries off this Mac.
    nonisolated static let webSearchEnabledKey = "webSearchEnabled"
    /// Settings (testing aid): show per-turn generation stats — context tokens +
    /// tok/s — under each assistant answer. Default OFF; MLX tiers only.
    nonisolated static let showGenerationStatsKey = "showGenerationStats"
    /// Settings: reasoning budget — ThinkingMode rawValue (auto/always/fast).
    nonisolated static let thinkingModeKey = "thinkingMode"
    /// Agent Interaction Log: OPT-IN, OFF BY DEFAULT. When true, `conversationLog`
    /// captures every MCP tool call's full request + response text (on-device
    /// only, capped at the newest 500, one-tap Clear). `nonisolated` so the
    /// store's `isEnabled` predicate — read from the server's dispatch path —
    /// can check it off the main actor.
    nonisolated static let conversationLogEnabledKey = "mcp.conversationLog.enabled"
    /// The heartbeat consent toggle — OFF by default (a persisted pulse history
    /// is a consent surface, not a convenience; Kev's default to flip).
    nonisolated static let heartbeatEnabledKey = "heartbeat.enabled"
    /// One-shot: the call-encryption key has been migrated to Touch-ID protection.
    /// Guards the (prompt-triggering) reassert so it runs once, not every launch.
    static let callKeyProtectionMigratedKey = "calls.keyProtectionMigrated"
    /// Call-subsystem diagnostics — pairs with StereoCallRecorder's trail so a full
    /// record→transcribe QA pass is one `log stream` predicate.
    private static let callLog = Logger(subsystem: "app.m1k3", category: "calls")
    /// Self-wiring quarantine outcomes (IDs/counts only, never titles).
    private static let securityLog = Logger(subsystem: "app.m1k3", category: "security")
    /// Brain load / swap diagnostics — the most common field issue ("stuck/failed
    /// download"); pairs with M1K3MLX's mlx-load trail under one predicate.
    private static let brainLog = Logger(subsystem: "app.m1k3", category: "mlx-load")
    /// Embedding service load + reindex decisions (the suspected "stale vector
    /// space" class behind a search that finds nothing it should).
    private static let embedLog = Logger(subsystem: "app.m1k3", category: "embeddings")
    /// Voice input (dictation / STT) lifecycle in the app shell.
    private static let voiceLog = Logger(subsystem: "app.m1k3", category: "stt")
    /// Memory-graph store availability.
    private static let memoryLog = Logger(subsystem: "app.m1k3", category: "memory-graph")
    /// The user has upgraded voice input to WhisperKit — restored on launch so it
    /// auto-loads instead of silently reverting to Apple Speech (guarded by the
    /// model being on disk, never a silent re-download).
    static let whisperEnabledKey = "transcription.whisperEnabled"
    /// Set once the user enables call transcription, so it reloads the batch model
    /// on launch (when on disk) instead of reverting to OFF and silently parking
    /// every recorded call. Mirrors `whisperEnabledKey` for the batch path.
    static let callTranscriptionEnabledKey = "calls.transcriptionEnabled"
    /// The chosen WhisperKit accuracy tier (tiny/base/small). Restored on launch;
    /// the provider is built from it in `init`, so a change applies on next launch.
    static let whisperModelKey = "transcription.whisperModel"
    /// Auto-route the brain via the EscalationLadder (ADR 0001) instead of a fixed
    /// manual pick. Default OFF — opt-in, fully reversible. When on, M1K3 picks its
    /// own tuned model per the policy (the MLX floor) — "Prefer Apple on-device" was
    /// cut from Settings 2026-07-13 (Kev-approved); the ladder's `preferAppleOnDevice`
    /// input is now always `false` (see resolvedAutoRouteTier).
    nonisolated static let autoRouteBrainKey = "brain.autoRoute"

    /// The chosen brain (Mini / Lil / Big). Restored on launch, persisted on change.
    private(set) var selectedBrain: BrainTier = .mini

    /// Set by init when the one-time front-tier realignment fired; flushed to the
    /// user by `runStartupMaintenance` once there's a window to read it in.
    private var pendingFrontTierNotice: String?

    /// The effect-chain renderer behind the M1K3 Voice (Kokoro) tier — held so the
    /// voice character can be switched live rather than rebuilt.
    private let voiceRenderer: EffectfulSpeechProvider

    /// Persisted voice character (see `VoiceCharacter`). Absent = the signature
    /// M1K3 voice, so a stored preference is the only way to change how it sounds.
    nonisolated static let voiceCharacterKey = "voice.character"

    /// The live character, for the Settings picker.
    var voiceCharacter: VoiceCharacter {
        VoiceCharacter(persisted: UserDefaults.standard.string(forKey: Self.voiceCharacterKey))
    }

    /// Switch how M1K3 sounds, now — the next rendered chunk carries it, so a
    /// listener hears the change within a sentence rather than after a restart.
    func setVoiceCharacter(_ character: VoiceCharacter) {
        UserDefaults.standard.set(character.rawValue, forKey: Self.voiceCharacterKey)
        voiceRenderer.setChain(character.chain)
    }

    /// The downloading brain's name for progress labels (e.g. "Big M1K3").
    var downloadingBrainName: String {
        selectedBrain.displayName
    }

    /// Whether retrieval is on semantic MLX embeddings (vs the Hashing fallback).
    private(set) var usingMLXEmbeddings = false
    /// True while a full re-embed of the store is in flight.
    private(set) var isReindexing = false
    /// Memory-graph reindex reentrancy latch — deliberately separate from
    /// `isReindexing` (switchEmbeddings holds that for its whole body and
    /// finishes by running the graph pass).
    private var isMemoryGraphReindexing = false
    /// Set while a background job (reindex/warm) is deferred for heat, so the
    /// cooldown re-run is armed exactly once (Cool Head knob 1). Lives on the main
    /// class body — extensions can't hold stored properties.
    private var thermalRecoveryObserver: NSObjectProtocol?
    /// Companion observer: Low Power Mode toggles fire the power-state
    /// notification, not the thermal one (see armThermalRecovery).
    private var powerRecoveryObserver: NSObjectProtocol?
    /// Last embeddings-switch outcome, surfaced to Settings.
    private(set) var embeddingStatus: String?

    /// OS (CoreSpotlight) index adapter behind the pure seam — the reconcile
    /// and hooks live in AppEnvironment+Spotlight.swift. On the main class
    /// body because extensions can't hold stored properties.
    let spotlightIndexer: any SystemSearchIndexing = SpotlightIndexer()
    /// The unit-pinned reconcile state machine (latch + coalesce + ordering);
    /// shares the adapter with the per-item donate/deindex hooks.
    /// @ObservationIgnored: infrastructure, not UI state — and @Observable's
    /// macro rejects a bare `lazy` stored property.
    @ObservationIgnored private(set) lazy var spotlightReconciler = SpotlightReconciler(indexer: spotlightIndexer)

    /// Runtime picker selection. Changing it re-points the inference façade at
    /// the chosen backend for the next turn — no rebuild, transcript preserved.
    var selectedRuntime: RuntimeOption = .appleFoundationModels {
        didSet {
            runtimeSelection.value = selectedRuntime
            // Warm MLX on selection so the ~1GB first-use download shows a
            // progress bar in Settings rather than a silent hang on the first
            // chat turn. Cheap/no-op once the weights are cached. Switching away
            // cancels the warm-up — the SingleFlightLoader lets any in-flight
            // download finish + cache; we just stop tracking it and clear the bar.
            preloadTask?.cancel()
            if selectedRuntime == .mlxGemma {
                preloadTask = Task { await preloadGemma() }
            } else {
                preloadTask = nil
                if modelLoad.isActive { modelLoad = .idle }
            }
            refreshInterimBridge()
        }
    }

    /// The in-flight MLX warm-up, so switching away can cancel it (idempotent).
    private var preloadTask: Task<Void, Never>?

    /// The background brain-upgrade journey (pure machine in M1K3Inference;
    /// coordinator in AppEnvironment+BrainUpgrade — internal setter because the
    /// coordinator lives in its own file; route every write through
    /// `BrainUpgradePolicy.transition`). ⚠️ Its download progress must NEVER be
    /// written to `modelLoad` — that drives the readiness gate, and this
    /// download is supposed to be invisible to a working chat.
    var brainUpgrade: BrainUpgradeState = .idle
    /// One-line transient notice ("Lil's awake — switched you over."), shown in
    /// the top banner slot and self-clearing.
    var brainUpgradeNotice: String?
    /// The in-flight background fetch, so `selectBrain`/the picker route can
    /// cancel it synchronously (single writer to the Hub cache dir).
    @ObservationIgnored var brainUpgradeFetchTask: Task<Void, Never>?
    /// The scheduled retry-backoff sleeper. Tracked SEPARATELY so
    /// `cancelBrainUpgradeFetch` kills it too — an untracked backoff could
    /// outlive a manual brain change and silently start a second Hub-cache
    /// writer (review catch, 2026-07-03).
    @ObservationIgnored var brainUpgradeRetryTask: Task<Void, Never>?
    /// Live network-path snapshot for OfferEligibility (expensive/constrained).
    @ObservationIgnored var brainUpgradePathMonitor: NWPathMonitor?
    @ObservationIgnored var brainUpgradeNetworkPath: NWPath?

    /// Progress of warming the MLX Gemma weights, surfaced in Settings (and the
    /// chat send path). Stays `.idle` for the Apple Foundation Models default.
    private(set) var modelLoad: ModelLoadState = .idle {
        didSet { refreshInterimBridge() }
    }

    /// The Advanced pane's "Import weights from a folder…" affordance —
    /// see AppEnvironment+WeightImport.swift for the run, WeightImportDisplay
    /// (M1K3MLX) for the pure outcome→copy mapping this wraps. Plain `var`
    /// (not `private(set)`): written from the extension file, same as
    /// `brainUpgrade` — `private(set)`'s setter is file-scoped in Swift, and
    /// the writer lives in a different file on purpose (AppEnvironment.swift
    /// stays the composition root, not a dumping ground for every feature's
    /// side-effect glue).
    var weightImportState: WeightImportRunState = .idle

    /// Last ingest outcome, surfaced to the UI.
    private(set) var lastIngestStatus: String?
    /// The last successfully ingested document's title, threaded properly for
    /// GreetingCard's ask-state ("Ask me about it") — never parsed back out of
    /// the display string above. Nil until a first success; survives failures.
    private(set) var lastIngestedTitle: String?
    /// True when the LAST ingest failed. Lets the failure banner pierce the
    /// GreetingCard's IngestBanner suppression — otherwise a failed drop while
    /// the card is up would be silent (or worse, revert to a stale earlier
    /// "Got it" ask-state as if the new file had landed).
    private(set) var lastIngestFailed = false
    private(set) var isIngesting = false
    /// Count of indexed knowledge items, for the document drawer / settings.
    private(set) var indexedItemCount = 0

    /// Call import outcome + count, surfaced to the Calls UI.
    private(set) var lastCallStatus: String?
    private(set) var isImportingCall = false
    private(set) var callCount = 0

    /// True while the mic is capturing a call (drives the recording indicator).
    private(set) var isRecording = false
    /// When the current capture started — drives the live elapsed clock in the
    /// Calls view. Nil whenever `isRecording` is false.
    private(set) var recordingStartedAt: Date?
    /// The most recent recording. Held so it can be (re)processed once the batch
    /// transcription model is ready.
    private(set) var lastRecordingURL: URL?
    /// Guards against two parked-recording recovery passes running at once (the
    /// launch chain + a manual enable). Not UI-facing, so observation is suppressed.
    @ObservationIgnored private var isRecoveringParked = false
    /// True while a recorded call is being transcribed → summarised → indexed.
    private(set) var isTranscribingCall = false
    /// True while the batch transcription model is downloading/loading.
    private(set) var isPreparingBatchTranscription = false
    /// Whether recorded calls can be transcribed now (model loaded).
    var batchTranscriptionReady: Bool {
        batchTranscriber.isAvailable
    }

    init() throws {
        // Bound the process-global MLX Metal cache before ANY MLX work (the
        // embedder below may be the first) — without it the cache grows to the
        // session's peak and never shrinks (~16GB footprint on easy queries).
        MLXMemoryBudget.applyOnce()

        // Weights store prep before ANY model-path read (the inventory below
        // is the first): ensure the Application Support root + backup
        // exclusion, and migrate a surviving legacy Caches store. Explicit
        // and sandboxed-app-only by design — see ModelStoreLocation. Cheap
        // after first run (same-volume renames even on migration day).
        ModelStoreLocation.prepareOnce()

        let url = try Self.storeURL()
        store = try KnowledgeStore(path: url.path)

        // The memory graph lives in its own file alongside knowledge.sqlite
        // (different lifecycle/consent/sync story — see MemoryStore's design
        // notes). Best-effort: if it can't open, the app runs unchanged and the
        // dual-write/recall tools simply stay inert.
        let memoryURL = url.deletingLastPathComponent().appendingPathComponent("memory.sqlite")
        do {
            memoryStore = try MemoryStore(path: memoryURL.path)
        } catch {
            // A corrupt/locked memory.sqlite silently disables remember/recall/
            // related/constellation — keep the inert nil fallback, but say why.
            memoryStore = nil
            Self.memoryLog.error("memory store open failed — memory tools inert: \(error.localizedDescription, privacy: .public)")
        }

        // The Agent Interaction Log lives in its own file, sibling to
        // memory.sqlite — same reasoning (separate consent/lifecycle: opt-in,
        // one-tap Clear, excluded from diagnostics). `isEnabled` reads the
        // Settings toggle live, off the main actor, so flipping it takes
        // effect immediately with no server restart. Best-effort: if it can't
        // open, MCP calls simply go uncaptured (byte-identical to logging
        // being off).
        let conversationLogURL = url.deletingLastPathComponent().appendingPathComponent("mcp-log.sqlite")
        do {
            conversationLog = try ConversationLogStore(
                path: conversationLogURL.path,
                isEnabled: { UserDefaults.standard.bool(forKey: Self.conversationLogEnabledKey) }
            )
        } catch {
            conversationLog = nil
            Self.memoryLog.error("conversation log store open failed — agent log inert: \(error.localizedDescription, privacy: .public)")
        }

        // The heartbeat pulse store — its own file, same separate-lifecycle
        // reasoning as the two above (capped rolling window, one-tap Clear,
        // excluded from diagnostics). Backup-excluded below: a pulse history
        // is a rolling status feed, not something Time Machine should archive.
        let heartbeatURL = url.deletingLastPathComponent().appendingPathComponent("heartbeat.sqlite")
        do {
            heartbeatStore = try HeartbeatStore(path: heartbeatURL.path)
            var resourceURL = heartbeatURL
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? resourceURL.setResourceValues(values)
        } catch {
            heartbeatStore = nil
            Self.memoryLog.error("heartbeat store open failed — heartbeat inert: \(error.localizedDescription, privacy: .public)")
        }

        // Embeddings define the stored vector space, so the choice must persist
        // across launches (Hashing query vectors against MLX-stored vectors would
        // not match). Honour the saved preference; switching at runtime re-embeds
        // the whole store (see switchEmbeddings).
        let preferMLX = UserDefaults.standard.bool(forKey: Self.embedderPrefersMLXKey)
        let baseEmbedder: any EmbeddingService = preferMLX
            ? MLXEmbeddingService()
            : HashingEmbeddingService()
        let swappable = SwappableEmbeddingService(baseEmbedder)
        embedder = swappable
        usingMLXEmbeddings = preferMLX

        // Restore the chosen brain (default Mini = Apple Foundation Models).
        // Decode via init(persisted:) so a stale "huge" (retired 2026-07-02)
        // migrates to Big instead of silently defaulting to Mini, then ease a
        // pick below its tier's hard floor (12B-Big needs 16GB, 2026-07-15) —
        // without this, a sub-floor Mac would RUN Big while the picker renders
        // it locked. Selectable picks pass through untouched (#81's honesty
        // rule). Write any change back so every later raw read sees a live,
        // selectable tier.
        let storedBrainRaw = UserDefaults.standard.string(forKey: Self.selectedBrainKey)
        let decoded = storedBrainRaw.flatMap(BrainTier.init(persisted:)) ?? .mini
        let physicalMemoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        // One-time realignment (2026-08-11): #117 made Lil the recommended front on
        // every Mac on measured evidence (3x quicker), but a recommendation never
        // reaches a machine that already has a pick — this one did not move Kev's
        // own Mac off Big, and he reported voice-first as slow the next day. Fires
        // once, records a marker, tells the user, and stays reversible in Settings.
        let realigned = FrontTierRealignment.plan(
            persisted: decoded,
            nudgeSpent: UserDefaults.standard.bool(forKey: Self.frontTierRealignedKey),
            recommended: BrainTier.recommended(forPhysicalMemoryGB: physicalMemoryGB)
        )
        // Spent by EVALUATING it, not by firing it — the window is the first launch
        // of a build that has this, full stop. Marking only the firing branch would
        // leave every Lil/Mini Mac permanently eligible, and then quietly undo the
        // first Big anyone deliberately picked in Settings (see plan's contract).
        UserDefaults.standard.set(true, forKey: Self.frontTierRealignedKey)
        if let realigned {
            frontTierLog.notice(
                "front tier realigned \(decoded.rawValue, privacy: .public) → \(realigned.tier.rawValue, privacy: .public) (once)"
            )
        }
        let brain = BrainTier.selectableOrEased(
            realigned?.tier ?? decoded, forPhysicalMemoryGB: physicalMemoryGB
        )
        if let storedBrainRaw, storedBrainRaw != brain.rawValue {
            UserDefaults.standard.set(brain.rawValue, forKey: Self.selectedBrainKey)
        }
        selectedBrain = brain
        // Held rather than shown: the notice auto-clears after 6s and init runs
        // before there's a window to read it in. Flushed from runStartupMaintenance.
        pendingFrontTierNotice = realigned?.notice

        // Generation IS swappable. The façade forwards to whichever backend the
        // brain selects; AFM is Mini + the fallback, the MLX slot is Lil/Big. The
        // slot starts on the chosen brain's model (or Big's, when Mini is active and
        // MLX isn't needed yet) so switching Lil↔Big just re-points the slot.
        let runtimeForBrain: RuntimeOption =
            brain.backing == .appleFoundationModels ? .appleFoundationModels : .mlxGemma
        let selection = RuntimeSelectionBox(runtimeForBrain)
        runtimeSelection = selection
        let afm = AppleFoundationModelsProvider()
        let initialMLXModelID = brain.mlxModelID ?? BrainTier.big.mlxModelID ?? ""
        // Generation cap follows the tier whose MODEL fills the slot (Big's when
        // Mini is active), not the selected brain: on a rotating-KV tier an
        // uncapped decode crosses the 8192 window mid-answer and silently
        // rotates the persona/grounding head out.
        let slotTier = brain.mlxModelID != nil ? brain : BrainTier.big
        let gemma = MLXGemmaProvider(
            modelID: initialMLXModelID,
            maxTokens: HistoryBudgetPolicy.generationTokenCap(
                for: slotTier, defaultCap: MLXGemmaProvider.defaultMaxTokens
            )
        )
        currentMLXProvider = gemma
        let mlxSlot = SwappableInferenceProvider(gemma)
        swappableMLX = mlxSlot
        let runtimeProvider = RuntimeInferenceProvider(
            selection: selection,
            interimOverride: interimRuntimeOverride,
            backends: [
                .appleFoundationModels: afm,
                .mlxGemma: mlxSlot,
            ],
            fallback: afm
        )
        provider = runtimeProvider
        // Capture the review model (already default-initialised) rather than self —
        // self isn't fully initialised here. The agent's open_link tool routes a
        // link into the panel on the MainActor.
        let review = review
        responder = Self.makeAgentResponder(
            store: store,
            embedder: swappable,
            provider: runtimeProvider,
            onOpenLink: { url in
                Task { @MainActor in review.open(url: url) }
            },
            deepDelegation: deepDelegationHook
        )

        // TTS seam: Built-in Apple voice wrapped in a swappable façade so the
        // premium Kokoro tier can drop in without rebuilding any caller.
        builtinSpeech = AVSpeechProvider()
        // The renderer is built here, not left to KokoroSpeechProvider's default,
        // so the voice character stays switchable at runtime (Settings) instead of
        // being frozen into a provider we'd have to rebuild — engine, taps and all —
        // to change how M1K3 sounds.
        let renderer = EffectfulSpeechProvider(
            chain: VoiceCharacter(
                persisted: UserDefaults.standard.string(forKey: Self.voiceCharacterKey)
            ).chain
        )
        voiceRenderer = renderer
        kokoro = KokoroSpeechProvider(renderer: renderer)
        speech = SwappableSpeechProvider(builtinSpeech)
        selectedVoiceTier = UserDefaults.standard.string(forKey: Self.selectedVoiceTierKey)
            .flatMap(VoiceTier.init(rawValue:)) ?? .builtin

        // Voice input: WhisperKit first (better accuracy, but unavailable until
        // its model loads), Apple Speech as the always-on fallback. So dictation
        // works on Apple Speech day one and upgrades to WhisperKit on demand.
        let whisperDownloadBase = url.deletingLastPathComponent()
        let whisperVariant = Self.resolveWhisperVariant(downloadBase: whisperDownloadBase)
        selectedWhisperModel = whisperVariant
        whisperKit = WhisperKitProvider(model: whisperVariant.modelID, downloadBase: whisperDownloadBase)
        transcription = TranscriptionRouter(providers: [whisperKit, AppleSpeechTranscriber()])
        batchTranscriber = WhisperKitBatchTranscriber(
            model: whisperVariant.modelID, downloadBase: whisperDownloadBase
        )

        let documentIngester = DocumentIngester(store: store, embedder: embedder)
        ingester = documentIngester
        // Multi-conversation history (GRDB) + auto-titling via the routed
        // provider; the legacy transcript.json imports once (factory runs the
        // migrator BEFORE init so resume-most-recent finds the import).
        let chatHistory = Self.makeChatHistoryStore(in: url.deletingLastPathComponent())
        chat = ChatSession(
            responder: responder,
            history: chatHistory,
            titler: ProviderConversationTitler(provider: runtimeProvider),
            distillation: Self.makeMemoryDistillation(
                store: store,
                embedder: swappable,
                ingester: documentIngester,
                fallback: runtimeProvider,
                // Wire the graph seam so distilled facts ALSO populate the temporal
                // memory graph (was corpus-only — the empty-graph root cause).
                graph: memoryStore.map { DistilledFactGraphAdapter(store: $0) as any DistilledFactGraphWriting }
            ),
            autoCaptureEnabled: { Self.memoryAutoCaptureEnabled() }
        )

        // Calls: encrypted-at-rest store (key from the Keychain), indexed into the
        // same knowledge graph, summarised by AFM (quick) + the active runtime (deep).
        let callsURL = url.deletingLastPathComponent().appendingPathComponent("calls.sqlite")
        callPersistence = Self.makeCallPersistence(at: callsURL)
        callIngester = CallIngester(store: store, embedder: embedder)
        callSummarizer = SummarizationPipeline(quickProvider: afm, deepProvider: runtimeProvider)
        recordingsDir = url.deletingLastPathComponent().appendingPathComponent("recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

        refreshCounts()
        Task { await self.runStartupMaintenance() }

        // Wire avatar + word highlight ↔ speech after all stored properties are
        // initialized (see the Voice output extension).
        wireSpeechCallbacks()
        // Late-bind delegate_deep's handler (the tool was built above, before
        // self existed). Weak: the tool must never keep the environment alive.
        deepDelegationHook.install { [weak self] task in
            guard let self else { return "Error: M1K3 is shutting down." }
            return await self.startDeepDelegation(task)
        }
        Self.resetVoiceModeFlagAtLaunch()
        mcpHost = MCPHostController(environment: self)
        mcpHost.startIfEnabled()
        menuBarAsk = MenuBarAsk(environment: self)
        // Cheap + synchronous (registration only) — see AppEnvironment+MetricKit.swift.
        startMetricKitCollection()
        // The heartbeat's coarse check loop (no-op while the toggle is off) —
        // see AppEnvironment+Heartbeat.swift.
        startHeartbeatLoop()

        // Warm a restored MLX brain (Lil/Big) on launch so it's ready to answer;
        // Mini (Apple) needs nothing. Setting selectedRuntime drives the existing
        // preload path + the progress UI. No-op/fast once the weights are cached.
        if brain.mlxModelID != nil {
            selectedRuntime = .mlxGemma
        }

        // Restore M1K3 Voice only if it was chosen AND already staged — never kick
        // a silent ~354 MB re-download on launch.
        if selectedVoiceTier == .m1k3Voice, kokoro.isModelStaged {
            Task { await prepareM1K3Voice() }
        }

        // Restore WhisperKit voice input the same way — only if the user upgraded to
        // it AND the model is on disk (else stay on Apple Speech rather than trigger
        // a silent ~142 MB re-download).
        if UserDefaults.standard.bool(forKey: Self.whisperEnabledKey), whisperKit.isModelDownloaded {
            Task { await enableWhisperKit() }
        }

        // Same restore for batch CALL transcription — without it the setting reverted
        // to OFF every launch and recorded calls parked silently (the bug Kev hit).
        // Then recover any recordings parked in a prior session: if the restore made
        // transcription ready they transcribe now; otherwise the user sees how many
        // are waiting. Chained so recovery sees the restored availability.
        Task {
            await restoreCallTranscriptionIfEnabled()
            await recoverParkedRecordings()
        }
    }

    /// Ingest a user-selected / dropped file (PDF or text) into the store.
    func ingest(url: URL) async {
        isIngesting = true
        defer { isIngesting = false }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let title = url.deletingPathExtension().lastPathComponent
        do {
            let result: DocumentIngester.IngestResult
            if url.pathExtension.lowercased() == "pdf" {
                let data = try Data(contentsOf: url)
                result = try await ingester.ingestPDF(title: title, data: data, sourceRef: url.absoluteString)
            } else {
                let text = try String(contentsOf: url, encoding: .utf8)
                result = try await ingester.ingest(title: title, text: text, sourceRef: url.absoluteString)
            }
            let dedup = result.wasDeduped ? " (already indexed)" : ""
            lastIngestStatus = "Indexed “\(title)” — \(result.chunkCount) chunks\(dedup).\(spotlightTipIfDue())"
            lastIngestedTitle = title
            lastIngestFailed = false
            refreshCounts()
            scheduleIngestStatusDismissal(of: lastIngestStatus)
            if !result.wasDeduped { await spotlightDonate(itemID: result.itemID) }
        } catch {
            // Failures deliberately do NOT auto-dismiss — a failed drop must
            // stay visible until the next ingest replaces it (the banner
            // pierces the greeting-card suppression for the same reason).
            lastIngestStatus = "Couldn’t index “\(title)”: \(error.localizedDescription)"
            lastIngestFailed = true
        }
    }

    /// Success banners are a moment, not a fixture: auto-clear after a beat.
    /// Compare-and-clear so a newer ingest's status is never clobbered by an
    /// older banner's timer. Also the fix for the stale-resurrection bug: the
    /// banner is suppressed while the GreetingCard is up, so an uncleared
    /// status would POP UP when the first sent message retires the card —
    /// after the moment has passed — and then never leave.
    private func scheduleIngestStatusDismissal(of status: String?, after seconds: Double = 8) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !self.lastIngestFailed, self.lastIngestStatus == status else { return }
            self.lastIngestStatus = nil
        }
    }

    /// Send a user message: drives avatar thinking → generating → idle, then
    /// hands off to ChatSession. The speech delegate handles the speaking→idle
    /// transition if the user taps Speak on the response.
    func send(_ text: String, images: [ImageAttachment] = []) async {
        // Backstop: never run a turn before the active brain is loaded into memory.
        // The chat surface already gates this (canSend + the readiness overlay), but
        // other entry points funnel here too — the menu-bar "Continue in chat", or a
        // dictation that finishes just as readiness flips — so one guard protects them
        // all. (The dedicated ask paths — MenuBarAsk, MCP — guard themselves.)
        guard isReady else { return }
        // Auto-routing (opt-in) picks the brain per the ladder before the turn.
        // No-op when off or when the pick is unchanged, so the default path is intact.
        applyAutoRouteIfEnabled()
        // Prudent compute (always on, 2026-07-13): fold this turn's thermal/low-power
        // pressure into the cool-head state so the agent loop eases off when the Mac
        // runs hot. Never swaps the brain.
        applyCoolHead()
        let clock = ContinuousClock()
        let started = clock.now
        avatar.setActivity(.thinking)
        // After a brief pause (RAG lookup), advance to .generating so Sparrow
        // bounces while the LLM streams. Self-cancelling if the response is fast.
        let advance = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self else { return }
            if case .thinking = self.avatar.state.activity {
                self.avatar.setActivity(.generating)
            }
        }
        // Auto-speak rides the same streaming message this send is about to
        // create — begin BEFORE the send so the baseline pins this turn.
        beginAutoSpeakSession()
        await chat.send(text, images: images)
        advance.cancel()
        // A failed turn earns the error earcon (the gate mutes it if M1K3 is
        // mid-speech, which a failure here never is).
        let answerFailed: Bool
        if case .failed = chat.messages.last?.status {
            answerFailed = true
            soundEffects.play(.error)
        } else {
            answerFailed = false
            if let responseText = chat.messages.last?.text {
                surfaceCodeArtifact(from: responseText)
            }
            // Successful answer: ping if the user tabbed away during a long think
            // (opt-in, backgrounded-only — the policy decides). Failures don't ping.
            await maybeNotifyTurnFinished(
                duration: clock.now - started,
                appActive: NSApplication.shared.isActive
            )
        }
        // The between-turns beat for the capability ladder: failures and
        // long/capped turns count as felt struggles (which can re-arm a parked
        // offer); a successful answer may raise the offer or complete a
        // consented staged swap at this idle moment.
        let metrics = chat.messages.last?.metrics
        // Same explicit defaultCap as the provider construction sites — the
        // composition root passes the MLX truth instead of trusting the
        // policy's mirrored literal (review nit on #22; the 116-F1 test
        // still pins the mirror for everyone else).
        let cap = HistoryBudgetPolicy.generationTokenCap(
            for: selectedBrain, defaultCap: MLXGemmaProvider.defaultMaxTokens
        )
        evaluateBrainUpgradeAfterAnswer(
            questionCharacters: text.count,
            answerFailed: answerFailed,
            generationHitTokenCap: metrics.map { $0.generationTokens >= cap } ?? false
        )
        // The intro invitation rides the same beat but only counts wins.
        if !answerFailed { evaluateIntroductionOfferAfterAnswer() }
        // Only reset to idle if the avatar isn't already in a speaking state
        // (e.g. auto-TTS path sets .speaking before we return here).
        if case .speaking = avatar.state.activity { return }
        avatar.resetToIdle()
    }

    private func surfaceCodeArtifact(from responseText: String) {
        let artifacts = CodeBlockDetector.detect(in: responseText)
        // MVP: surface only the first artifact; multi-block picker is a follow-up.
        guard let first = artifacts.first else { return }
        review.open(artifact: first)
        // Documents the model wrapped in <artifact> tags now live in the panel —
        // replace the raw tag blocks in the bubble with a breadcrumb. No-op when the
        // artifact came from a fenced block (those stay inline, as code always has).
        chat.stripArtifactTagsFromLastMessage()
    }

    // speak/stopSpeaking/wireSpeechCallbacks live in AppEnvironment+VoiceMode.swift
    // (relocated to keep this class body under SwiftLint's ceilings).

    // MARK: - Voice input

    /// Whether any recogniser can serve right now (WhisperKit-if-loaded, else
    /// Apple Speech). Drives the mic button's enabled state.
    var canDictate: Bool {
        transcription.activeProvider != nil
    }

    /// The engine voice input would currently use, for the Settings label.
    var activeTranscriberName: String {
        transcription.activeProviderName ?? "Unavailable"
    }

    /// The WhisperKit tier to build at launch: an explicit pick wins, else keep an
    /// already-downloaded model rather than silently switch a returning user to the
    /// new `small.en` default (a fresh ~480 MB download). Pure decision in
    /// `WhisperModelVariant.resolve`; this just supplies the real on-disk check.
    private static func resolveWhisperVariant(downloadBase: URL) -> WhisperModelVariant {
        WhisperModelVariant.resolve(
            stored: UserDefaults.standard.string(forKey: whisperModelKey),
            isInstalled: { WhisperKitProvider.isModelDownloaded(model: $0.modelID, downloadBase: downloadBase) }
        )
    }

    /// Choose the WhisperKit accuracy tier. Persisted; the provider is built from
    /// this in `init`, so the change takes effect on the next launch (the live
    /// router is immutable — a runtime hot-swap is a deliberate future follow-up).
    func selectWhisperModel(_ variant: WhisperModelVariant) {
        guard variant != selectedWhisperModel else { return }
        selectedWhisperModel = variant
        UserDefaults.standard.set(variant.modelID, forKey: Self.whisperModelKey)
    }

    /// Whether the live WhisperKit STT engine is loaded and currently serving
    /// (vs the always-available Apple Speech fallback). Voice mode reads this to
    /// decide whether to kick a WhisperKit load on entry — the better engine, and
    /// the home of the `[Music]`/`[BLANK_AUDIO]` cleaning.
    var isWhisperKitActive: Bool {
        whisperKit.isAvailable
    }

    /// Download + load WhisperKit's model so voice input upgrades from Apple
    /// Speech to WhisperKit (the router prefers it once available).
    func enableWhisperKit() async {
        guard !isPreparingWhisper else { return }
        isPreparingWhisper = true
        // WhisperKit's init bundles download + CoreML compile opaquely (it reports
        // only 0.05 then 1.0), so there's no honest fraction to show — an
        // indeterminate "Preparing…" spinner, never a bar stuck at 5% mislabelled as
        // a download. (Wiring WhisperKit's modelStateCallback for real download
        // progress on a fresh fetch is a follow-up.)
        whisperLoad = .preparing
        do {
            try await whisperKit.prepareModel { _ in }
            isPreparingWhisper = false
            whisperLoad = .ready
            // Remember the upgrade so the next launch auto-loads WhisperKit instead
            // of silently dropping back to Apple Speech.
            UserDefaults.standard.set(true, forKey: Self.whisperEnabledKey)
        } catch {
            isPreparingWhisper = false
            whisperLoad = .failed(message: error.localizedDescription)
        }
    }

    /// Whether a downloaded-tier brain's weights are already on disk. Mini (Apple
    /// Foundation Models) has nothing to download, so it's never "downloaded" here.
    func isBrainDownloaded(_ tier: BrainTier) -> Bool {
        guard let modelID = tier.mlxModelID else { return false }
        return brainInventory.isInstalled(modelID: modelID)
    }

    /// Choose a brain: persist it, re-point the active provider, and (for Lil/Big)
    /// warm the model so onboarding / Settings show a real download bar. Mini is
    /// instant — Apple Foundation Models, no download.
    ///
    /// Returns `true` when the pick was the already-loaded no-op — `modelLoad`
    /// will NOT transition (it's already .ready), so a caller waiting on an
    /// onChange for readiness (onboarding's waking screen) must advance itself.
    @discardableResult
    func selectBrain(_ tier: BrainTier) -> Bool {
        // Refuse a brain switch WHILE a deep dive is running on the MLX slot:
        // re-pointing `swappableMLX` (and loading a new model into it) under
        // the in-flight delegated generation both corrupts that run's provider
        // and spins a second MLX loop, breaking the one-decode-loop invariant
        // the whole delegate_deep design rests on (2026-07-25 review finding).
        // The dive you started on this brain finishes on it; switch after.
        if deepDelegationTaskLabel != nil {
            Self.brainLog.notice("selectBrain \(tier.rawValue, privacy: .public): refused — deep dive in flight")
            return true // no transition, same as the already-loaded no-op
        }
        // A brain switch is one of the few moments AFM availability can matter
        // afresh (e.g. the user just enabled Apple Intelligence and came back)
        // — drop the gate's snapshot so its next read re-probes live.
        invalidateBridgeAFMCache()
        // Already on this exact MLX brain and it's loaded — re-selecting would spin up
        // a fresh MLXGemmaProvider (cold persona-KV prefix) and release the warm one,
        // repaying a multi-GB load + persona prefill for nothing. The predicate is
        // BrainSwitcher's (unit-pinned there): non-ready falls through so onboarding
        // "Try again" and first-wake re-attempt; Mini (no mlxModelID) is never guarded.
        if BrainSwitcher.reselectIsNoOp(
            tier: tier, selected: selectedBrain, load: modelLoad,
            loadedModelID: currentMLXProvider.modelIdentifier
        ) {
            Self.brainLog.notice("selectBrain \(tier.rawValue, privacy: .public): already loaded, no-op")
            // Defense-in-depth: keep the upgrade machine consistent even on the
            // no-op path, rather than relying on the policy's non-Mini
            // short-circuit staying total (an implicit cross-file coupling).
            recomputeBrainUpgradeState()
            return true
        }
        Self.brainLog.notice("selectBrain \(tier.rawValue, privacy: .public): model=\(tier.mlxModelID ?? "appleFoundationModels", privacy: .public)")
        // Single writer to the Hub cache: any explicit brain change cancels the
        // background upgrade fetch FIRST (the partial snapshot survives and
        // resumes wherever it's next wanted). State recomputes below.
        cancelBrainUpgradeFetch()
        selectedBrain = tier
        UserDefaults.standard.set(tier.rawValue, forKey: Self.selectedBrainKey)
        // Deliberately NOT writing hasChosenBrainKey here (removed 2026-07-03):
        // that key is the first-run WINDOW GATE, and M1K3App binds it via
        // @AppStorage — a write mid-download would swap HelloView/BrainPickerView
        // out from under their own progress UI. The gate is owned exclusively by
        // the onComplete closures in M1K3App (and routeToOnboardingBrainPicker /
        // Settings re-run for the false direction). Note the old write was also
        // unreachable on the no-op path above — the guard returns first.
        let oldMLX = currentMLXProvider
        if let modelID = tier.mlxModelID {
            // Rotating-KV tiers get a capped decode so prefill + generation fit
            // the window together (see HistoryBudgetPolicy.rotatingGenerationTokenCap).
            let mlx = MLXGemmaProvider(
                modelID: modelID,
                maxTokens: HistoryBudgetPolicy.generationTokenCap(
                    for: tier, defaultCap: MLXGemmaProvider.defaultMaxTokens
                )
            )
            currentMLXProvider = mlx
            swappableMLX.setProvider(mlx)
            selectedRuntime = .mlxGemma // didSet warms it + streams progress
        } else {
            selectedRuntime = .appleFoundationModels // didSet clears the bar
        }
        oldMLX.releaseMemory()
        recomputeBrainUpgradeState()
        return false
    }

    /// Deep-link the next OnboardingView to the brain-picker step (the honest
    /// download UI: explicit Download button, per-tier progress, Try-again/Use-Mini
    /// fallback) instead of a silent in-place pull. Used by Settings "Change brain…"
    /// and the chat toolbar's brain switcher when a tier needs downloading — the
    /// actual brain write still happens via `selectBrain` inside onboarding. One
    /// home for the two-key dance so it can't drift between call sites.
    func routeToOnboardingBrainPicker() {
        // The picker will drive its own download — hand it sole ownership of
        // the Hub cache before the window swaps.
        cancelBrainUpgradeFetch()
        UserDefaults.standard.set(true, forKey: M1K3App.onboardingStartAtBrainKey)
        UserDefaults.standard.set(false, forKey: Self.hasChosenBrainKey)
    }

    /// Warm the current brain's MLX weights, folding download progress into
    /// `modelLoad` so the UI shows a real bar. Idempotent: returns fast once the
    /// model is cached. Runs off the main actor; progress hops back to update state.
    private func preloadGemma() async {
        // No re-entrancy guard needed: switching brains cancels any prior warm-up
        // first, and the SingleFlightLoader dedupes the underlying download even
        // if two briefly overlap. On cancellation we write nothing — whoever is
        // the current selection (the didSet, or a newer warm-up) owns modelLoad,
        // so a late-completing cancelled task can't clobber it.
        modelLoad = .progress(0)
        // Dial-up "connecting…" hum only when weights aren't already cached —
        // i.e. a real download the user waits through, not the silent launch
        // re-warm of a brain already on disk (no modem screech on every launch).
        // The defer guarantees it stops on every exit: ready, cancel, or error.
        let willDownload = !isBrainDownloaded(selectedBrain)
        if willDownload, dialUpSoundEnabled { soundEffects.startLoop(.dialup) }
        defer { soundEffects.stopLoop(.dialup) }
        let mlx = currentMLXProvider
        do {
            try await mlx.prepare { fraction in
                // Only apply while still downloading. A progress callback fired
                // near completion enqueues its main-actor hop *after* the `.ready`
                // write below; the guard makes that stale hop a no-op instead of
                // regressing the bar to 99% forever.
                Task { @MainActor in
                    // While downloading, reflect the fraction. The moment the
                    // download completes (fraction reaches 1.0) the slow part
                    // begins — loading the weights into Metal, with no honest
                    // fraction — so switch to the indeterminate `.preparing`
                    // spinner instead of leaving a frozen "…100%" bar that reads
                    // as a blocked app.
                    if case .downloading = self.modelLoad {
                        self.modelLoad = fraction >= 1 ? .preparing : .progress(fraction)
                    }
                }
            }
            if Task.isCancelled { return }
            modelLoad = .ready
            // Ping "ready" only after a real download/load (not a cached warm),
            // and only if you've tabbed away — the same background-only gate as
            // the long-turn ping. appActive read here on the main actor.
            if willDownload {
                await maybeNotifyModelReady(
                    modelName: selectedBrain.displayName,
                    appActive: NSApplication.shared.isActive
                )
            }
            warmPersonaPrefixAfterLoad(mlx)
        } catch is CancellationError {
            // Deliberately switched away mid-load — leave modelLoad to the current
            // selection (the didSet already cleared the bar).
        } catch {
            if !Task.isCancelled {
                // A 404/gated-repo/disk-full/checksum failure is non-transient, so
                // Retry never fires onRetry — it lands here and only set UI state.
                Self.brainLog.error("brain load failed [\(mlx.modelIdentifier, privacy: .public)]: \(error.localizedDescription, privacy: .public)")
                modelLoad = .failed(message: error.localizedDescription)
            }
        }
    }

    /// Post-load persona-prefix warm — `warmEmbedderOnLaunch`'s sibling for
    /// the OTHER half of the measured first-turn tax (embedder ~4.0 s; prefix
    /// build ~2.1 s on lil (2507) / **~8.5 s on big (12B)** — SelfTest
    /// EMBEDWARM/PREFIXWARM re-run 2026-07-31 post-reshuffle, evidence in
    /// scratch/eval-2026-07-31-prefixwarm/; the 12B build is ~2.6× the e4b-era
    /// figure, so this warm is far more load-bearing than first documented).
    /// Pre-builds the (persona × tools) KV the interactive
    /// chat's FIRST turn will ask for, in the background, behind the same
    /// thermal gate. Best-effort by design:
    /// - A turn racing the warm queues behind it on the ModelContainer —
    ///   worst case it pays roughly the build it would have paid anyway.
    /// - A web-toggle/persona change after the warm is a cache miss (the turn
    ///   builds inline, pre-warm behavior), never a wrong prefix — the cache
    ///   is keyed by (model × tools × persona).
    /// - A brain swap mid-warm wastes the old provider's build; its cache dies
    ///   with the provider's `releaseMemory()`.
    /// Key parity with the live turn is structural, not aspirational: the tool
    /// list comes from the SAME `interactiveAgentTools` builder the responder
    /// consults each turn (callbacks are no-ops — only definitions render into
    /// the prefix), and the MLX side shares its key derivation with
    /// `makeToolTurnSession` (pinned in MLXPrefixInputsTests).
    /// Internal (not private): AppEnvironment+DeepDelegation re-warms the
    /// restored resident brain after an escalated dive releases the slot.
    func warmPersonaPrefixAfterLoad(_ mlx: MLXGemmaProvider) {
        guard Self.backgroundWorkAllowed() else {
            // Hot right now (the model download itself can heat the Mac):
            // arm the cooldown retry, or this session would pay the inline
            // build on its first turn forever — the embedder sibling gets
            // the same recovery treatment (review fold, #27).
            armThermalRecovery()
            return
        }
        // Warm BOTH palettes that really exist. Until 2026-08-12 this warmed a
        // THIRD one that nothing ever asks for: it passed onOpenLink but not
        // deepDelegation, while the live responder (AppEnvironment.swift:684)
        // always passes both — so the warmed key matched no caller and the ~2.1s
        // build was paid at launch AND again on the first chat turn AND again on
        // the first agent ask. Caught by reading two `persona prefix built` lines
        // in the unified log with different tool sets, not by any test: the key is
        // a fingerprint of the tool SET, and nothing checks that the set we warm
        // is a set anyone wants.
        //
        // Order matters — the second warm becomes MRU, and the cache holds two.
        // Interactive goes last because a person waiting on their first chat turn
        // beats an agent's first ask.
        let headlessTools = Self.interactiveAgentTools(
            store: store, embedder: embedder,
            onHits: { _ in }, onOpenLink: nil
        ).map(\.toolDefinition)
        let interactiveTools = Self.interactiveAgentTools(
            store: store, embedder: embedder,
            onHits: { _ in }, onOpenLink: { _ in }, deepDelegation: deepDelegationHook
        ).map(\.toolDefinition)
        // weak: a brain swap mid-warm must not have this task pin the OUTGOING
        // provider's multi-GB weights alive while the new brain's are loading
        // (releaseMemory's reclaim would silently wait on the warm otherwise).
        Task.detached(priority: .utility) { [weak mlx] in
            // Sequentially: one ModelContainer, and the coalescer only dedupes
            // IDENTICAL keys — two concurrent builds of different keys would just
            // queue on the actor anyway, with the loser's ordering unpredictable.
            await mlx?.warmPersonaPrefix(tools: headlessTools)
            await mlx?.warmPersonaPrefix(tools: interactiveTools)
        }
    }

    /// Switch the active embedder and re-embed the whole store so retrieval moves
    /// to (or back from) semantic MLX vectors. The choice persists; on failure the
    /// façade rolls back so query + stored vectors stay in the same space.
    func switchEmbeddings(toMLX useMLX: Bool) async {
        guard useMLX != usingMLXEmbeddings, !isReindexing else { return }
        isReindexing = true
        embeddingStatus = useMLX
            ? "Loading MLX embedder and rebuilding the index…"
            : "Rebuilding the index with the Hashing embedder…"
        defer { isReindexing = false }

        let newEmbedder: any EmbeddingService = useMLX
            ? MLXEmbeddingService(onLoadProgress: { fraction in
                Task { @MainActor in
                    self.embeddingStatus = "Downloading embedder… \(Int((fraction * 100).rounded()))%"
                }
            })
            : HashingEmbeddingService()
        embedder.setEmbedder(newEmbedder)
        do {
            let count = try await store.reindexEmbeddings(
                using: newEmbedder,
                fingerprint: EmbeddingText.storeFingerprint(embedder: newEmbedder.fingerprint)
            )
            usingMLXEmbeddings = useMLX
            UserDefaults.standard.set(useMLX, forKey: Self.embedderPrefersMLXKey)
            let label = useMLX ? "MLX Qwen3-Embedding" : "Hashing"
            Self.embedLog.notice("switched embeddings to \(label, privacy: .public), reindexed \(count) chunk(s)")
            embeddingStatus = "Reindexed \(count) chunk\(count == 1 ? "" : "s") with \(label)."
        } catch {
            // Reindex writes atomically, so the store still matches the previous
            // embedder — roll the façade back to it.
            embedder.setEmbedder(usingMLXEmbeddings ? MLXEmbeddingService() : HashingEmbeddingService())
            Self.embedLog.error("embedding switch failed, rolled back: \(error.localizedDescription, privacy: .public)")
            embeddingStatus = "Couldn’t switch embeddings: \(error.localizedDescription)"
        }
        MLXMemoryBudget.reclaim(label: "switchEmbeddings")
        // The graph's vectors live in the same embedding space — swap them too
        // (keyed on the same salted fingerprint, so a rollback above no-ops).
        await reindexMemoryGraphIfNeeded()
    }

    /// All indexed items, newest first, for the document manager — or one
    /// kind's slice (the memories surface passes `.memory`).
    func documents(kind: KnowledgeKind? = nil) -> [KnowledgeItem] {
        ((try? store.allItems(kind: kind)) ?? []).sorted { $0.createdAt > $1.createdAt }
    }

    /// Chunk count for one item (shown in the document list).
    func chunkCount(for id: UUID) -> Int {
        (try? store.chunks(forItem: id).count) ?? 0
    }

    /// Delete an item and everything it owns; refresh the counts.
    @discardableResult
    func deleteDocument(id: UUID) -> Bool {
        let deleted = (try? store.deleteItem(id: id)) ?? false
        if deleted {
            refreshCounts()
            // A delete must never leave a ⌘Space ghost — deindex regardless
            // of the Spotlight toggle (always safe, cheap).
            Task { await spotlightDeindex(id: id) }
        }
        return deleted
    }

    /// Re-tag a document's kind and coordinate Spotlight.
    ///
    /// Quarantining always deindexes from ⌘Space (same unconditional rule as
    /// delete — the OS index survives container resets; a ghost is worse than
    /// a redundant deindex call). Restoring re-donates if Spotlight is enabled
    /// and the new kind is donatable (the policy owns the allowlist).
    ///
    /// Returns true if the item was found; false if the id was unknown.
    @discardableResult
    func tagDocument(id: UUID, kind: KnowledgeKind) -> Bool {
        let changed = (try? store.setKind(id: id, newKind: kind)) ?? false
        guard changed else { return false }
        refreshCounts()
        // Fire-and-forget like deleteDocument's deindex. Known bound: a rapid
        // quarantine↔restore on the same id can land its two Spotlight ops out
        // of order, leaving the OS index briefly opposite to the DB — the next
        // launch reconcile rebuilds from store state and self-heals it (the
        // same guarantee that covers container-reset orphans).
        Task {
            if kind == .quarantined {
                await spotlightDeindex(id: id)
            } else {
                await spotlightDonate(itemID: id)
            }
        }
        return true
    }

    // MARK: - Calls

    /// Import a plain-text transcript as a call: parse → summarise → persist
    /// (encrypted) → index into the knowledge graph (so it's RAG-searchable).
    /// The headless, no-mic path to a real call while recording is still to come.
    func importCallTranscript(url: URL) async {
        isImportingCall = true
        defer { isImportingCall = false }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let title = url.deletingPathExtension().lastPathComponent
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let segments = TranscriptImporter.parse(text)
            guard !segments.isEmpty else {
                lastCallStatus = "“\(title)” had no readable lines."
                return
            }
            let transcript = segments
                .map { ($0.speaker.map { "\($0): " } ?? "") + $0.text }
                .joined(separator: "\n")
            let summary = await callSummarizer.summarize(transcript: transcript)
            let session = CallSession(
                startedAt: Date(),
                title: title,
                segments: segments,
                quickSummary: summary.quick,
                fullSummary: summary.full
            )
            try callPersistence.save(session)
            let ingestResult = try await callIngester.ingest(session)
            refreshCounts()
            if !ingestResult.wasDeduped { await spotlightDonate(itemID: session.id) }
            lastCallStatus = "Imported “\(title)” — \(segments.count) lines, indexed + searchable."
        } catch {
            lastCallStatus = "Couldn’t import “\(title)”: \(error.localizedDescription)"
        }
    }

    /// All stored calls, newest first.
    func calls() -> [CallSession] {
        (try? callPersistence.loadAll()) ?? []
    }

    /// Delete a call from both the encrypted store and the knowledge graph.
    @discardableResult
    func deleteCall(id: UUID) -> Bool {
        let removed = (try? callPersistence.delete(id: id)) ?? false
        // The call's graph node shares the call UUID; the Spotlight entry
        // tracks the KNOWLEDGE item, so the deindex gates on this delete —
        // never leave a ⌘Space ghost, never drop a still-live item either.
        let knowledgeDeleted = (try? store.deleteItem(id: id)) ?? false
        if removed { refreshCounts() }
        if knowledgeDeleted { Task { await spotlightDeindex(id: id) } }
        return removed
    }
}

// MARK: - Recording (consent-gated)

//
// Same-file extension — sees the class's private members (callLog, recorder,
// consentGate, …) while keeping the class body under type_body_length.

extension AppEnvironment {
    /// Whether recording can start without re-asking for consent.
    var recordingPreAuthorised: Bool {
        consentGate.isPreAuthorised
    }

    /// Log a consent affirmation, then start recording.
    func affirmConsentAndRecord(scope: ConsentScope) async {
        Self.callLog.notice("consent affirmed (scope=\(String(describing: scope), privacy: .public))")
        consentGate.affirm(scope: scope, at: Date())
        await startRecording()
    }

    /// Start capturing — only call once consent is in hand (pre-authorised or just
    /// affirmed). Captures the far-end (system audio) too when screen-recording
    /// permission is granted; falls back to mono mic otherwise. Surfaces failures
    /// rather than crashing.
    func startRecording() async {
        guard !isRecording else { return }
        do {
            let stereo = try await recorder.start()
            isRecording = true
            recordingStartedAt = Date()
            Self.callLog.notice("recording started (stereo=\(stereo, privacy: .public))")
            lastCallStatus = stereo
                ? "Recording… (both sides — speakers will be separated)"
                : "Recording… (mic only — grant Screen Recording to capture the other side)"
        } catch {
            Self.callLog.error("start failed: \(error, privacy: .public)")
            lastCallStatus = "Couldn’t start recording: \(error.localizedDescription)"
        }
    }

    /// Stop capturing. If the batch transcription model is ready, the recording is
    /// transcribed → summarised → encrypted → indexed straight away (the SAME
    /// CallIntelligencePipeline the import path proves). If not, it's held and the
    /// user is pointed at the Settings enable; `enableCallTranscription` picks it up.
    func stopRecording() async {
        guard isRecording else { return }
        let recorded = await recorder.stop()
        isRecording = false
        recordingStartedAt = nil
        guard let recorded else {
            lastRecordingURL = nil
            Self.callLog.error("stop: nothing recorded")
            lastCallStatus = "No audio was captured — check Microphone access in System Settings › Privacy & Security."
            return
        }
        // Move the recording out of the OS temp dir into durable storage BEFORE we
        // decide what to do with it — so a parked recording survives a relaunch /
        // temp sweep and can be recovered.
        let url = relocateToRecordings(recorded)
        lastRecordingURL = url
        if batchTranscriber.isAvailable {
            Self.callLog.notice("stop: recorded \(url.lastPathComponent, privacy: .public) → transcribing")
            Task { await processRecording(url: url) }
        } else {
            Self.callLog.notice("stop: recorded \(url.lastPathComponent, privacy: .public) → parked (transcription model not enabled)")
            // If relocation failed the file is still in the temp dir — recoverable
            // this session, but NOT across a relaunch. Warn so it isn't lost silently.
            let durable = url.path.hasPrefix(recordingsDir.path)
            lastCallStatus = durable
                ? "Recorded — enable call transcription in Settings to process it."
                : "Recorded — transcribe it now (enable call transcription); it may not survive a quit."
        }
    }

    /// Move a just-captured recording from the recorder's temp output into the
    /// durable recordings dir. On any failure the original URL is returned (still
    /// playable/transcribable this session) — relocation is for relaunch survival,
    /// never a reason to lose the recording.
    private func relocateToRecordings(_ source: URL) -> URL {
        let dest = recordingsDir.appendingPathComponent(source.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: source, to: dest)
            return dest
        } catch {
            Self.callLog.error("couldn't relocate recording to durable dir: \(error, privacy: .public)")
            return source
        }
    }

    func refreshCounts() { // internal: MCP remember tool refreshes after ingest
        indexedItemCount = (try? store.itemCount()) ?? indexedItemCount
        callCount = (try? callPersistence.count()) ?? callCount
    }
}

// MARK: - Composition helpers

//
// Same-file extension (keeps the class body under SwiftLint's type_body_length).

extension AppEnvironment {
    /// Whether the on-device model is actually available on this machine.
    var providerAvailable: Bool {
        provider.isAvailable
    }

    /// The global "is M1K3 usable yet" signal — the chat surface gates input on
    /// this. A weight-backed brain (MLX) reports `isAvailable == true` before its
    /// weights are on disk, so readiness for it hangs on `modelLoad` reaching
    /// `.ready`, not on availability — otherwise a turn fires against a model that's
    /// still downloading (the "interacted before ready" latent bugs).
    var readiness: AppReadiness {
        ModelReadiness.resolve(
            requiresWeights: selectedBrain.mlxModelID != nil,
            load: modelLoad,
            backendAvailable: providerAvailable
        )
    }

    /// True once the active brain is loaded and can serve a turn.
    var isReady: Bool {
        readiness.isReady
    }

    /// What the chat surface should do about readiness: `.open` (no gate),
    /// `.interim` (selected brain still downloading — Mini serves, show a
    /// banner, keep the input alive), or `.blocked` (mount the full
    /// ModelGateView). Pure policy in M1K3Inference (InterimBrainPolicy).
    var chatGate: ChatGate {
        InterimBrainPolicy.gate(
            readiness: readiness,
            selectedRequiresWeights: selectedBrain.mlxModelID != nil,
            afm: bridgeAFMAvailability
        )
    }

    private var bridgeAFMAvailability: AFMAvailability {
        if let cachedBridgeAFM { return cachedBridgeAFM }
        let value = afmAvailability
        // Only cache genuinely stable states — a transient `.notReady` (AFM
        // assets warming at launch) or a user-fixable block (they might enable
        // Apple Intelligence any moment) must re-probe, or the bridge freezes
        // on the first read for the whole session (2026-07-25 review finding).
        if value.isStableForCaching { cachedBridgeAFM = value }
        return value
    }

    /// Invalidate the gate's AFM snapshot (next read re-probes live).
    func invalidateBridgeAFMCache() {
        cachedBridgeAFM = nil
    }

    /// Keeps the façade's routing override in lock-step with the two reasons
    /// interactive turns front on Mini: the selected brain's weights are still
    /// downloading (`.interim`), or the MLX slot is busy with a delegate_deep
    /// run (one MLX decode loop, ever — the challenger-pinned constraint).
    /// Otherwise routing follows `selectedRuntime` untouched. Called from the
    /// didSets of everything it reads (`modelLoad`, `selectedRuntime`) and
    /// from the delegation start/finish — a computed value can't reach the
    /// Sendable box the provider reads at generate time. Internal: the
    /// delegation manager lives in its own file.
    func refreshInterimBridge() {
        let gate = chatGate
        let delegationFronting = deepDelegationTaskLabel != nil
            && selectedBrain.mlxModelID != nil
        let posture = InterimBrainPolicy.posture(
            gate: gate,
            delegationInFlight: delegationFronting
        )
        interimRuntimeOverride.value = posture.frontsOnMini ? .appleFoundationModels : nil
        if gate != lastBridgedGate {
            Self.brainLog.notice("chatGate → \(String(describing: gate), privacy: .public)")
            lastBridgedGate = gate
        }
    }

    /// Warm the restored brain's model on launch so readiness can reach `.ready`
    /// without the user having to fire a turn first. Mini (Apple Foundation Models)
    /// is instant — nothing to warm. An MLX brain restored from defaults is assigned
    /// directly in `init`, which SKIPS `selectedRuntime`'s didSet (Swift omits
    /// property observers during initialization), so nothing else kicks the load —
    /// this is that kick. Idempotent: `preloadGemma`/the SingleFlightLoader no-op
    /// once the weights are cached.
    func warmUpSelectedBrainOnLaunch() async {
        guard selectedBrain.mlxModelID != nil else { return }
        await preloadGemma()
    }

    /// Launch-time housekeeping off the init path: restore the user profile
    /// into the persona, the one-time embedder re-index check, then pre-warm the
    /// embedder so the first chat turn doesn't pay a cold model load.
    func runStartupMaintenance() async {
        // Rebuild the background-upgrade state from disk facts (never persisted
        // — a mid-download quit or failure self-heals here).
        recomputeBrainUpgradeState()
        // A brain swap the user didn't ask for has to be SAID, not just done.
        if let notice = pendingFrontTierNotice {
            pendingFrontTierNotice = nil
            showBrainUpgradeNotice(notice)
        }
        M1K3Persona.setUserProfile(try? store.meta(key: Self.userProfileMetaKey))
        installGenerationMetricsSink()
        await quarantineSelfWiringDocuments()
        await quarantineModelThinkingDocuments()
        await reindexIfEmbedderChanged()
        await reindexMemoryGraphIfNeeded()
        await warmEmbedderOnLaunch()
        await syncSpotlightIndex()
    }

    /// Keep M1K3's own wiring out of the retrievable index. Found live
    /// 2026-08-09: `search_knowledge` returned ABSOLUTE RULES 1, 2 and 3
    /// verbatim from an ingested copy of the prompt, so the rules could be
    /// RECITED without the model ever leaking them — a different door from the
    /// one the persona guards, and the only one that was open.
    ///
    /// The `.quarantined` kind was built for this in June and the re-tag was
    /// left as a manual operator action, where it sat undone for two months. A
    /// maintenance chore nobody performs is not a control, so it runs every
    /// launch: idempotent, and it catches the NEXT accidental ingest without
    /// anyone remembering. Best-effort — a scan failure must never block boot.
    private func quarantineSelfWiringDocuments() async {
        // Off the main actor: this reads every chunk of every retrievable item,
        // and runStartupMaintenance() inherits @MainActor from the class — so a
        // synchronous call here would scan the whole corpus on the thread that
        // draws the first frame (review catch, PR #115).
        let spans = SelfWiringQuarantine.spans(inPrompt: M1K3Persona.wiringText)
        let corpus = store
        let moved: [UUID]
        do {
            moved = try await Task.detached(priority: .utility) {
                try corpus.quarantineSelfWiring(spans: spans)
            }.value
        } catch {
            // A silent failure would make "the sweep never ran" indistinguishable
            // from "nothing to quarantine" — unacceptable for a security control.
            Self.securityLog.error(
                "self-wiring quarantine FAILED: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        guard !moved.isEmpty else { return }
        // IDs only, never titles: the whole point is that this content should
        // not be spreading, and a log line is another place it would live.
        Self.securityLog.notice(
            "self-wiring quarantine: \(moved.count, privacy: .public) item(s) re-kinded"
        )
        refreshCounts()
    }

    /// The sibling sweep: stored text that IS the model's scratchpad rather than
    /// knowledge (`ModelThinkingQuarantine`). Same shape, same reasons — off the
    /// main actor, loud on failure, every launch.
    private func quarantineModelThinkingDocuments() async {
        let corpus = store
        let moved: [UUID]
        do {
            moved = try await Task.detached(priority: .utility) {
                try corpus.quarantineModelThinking()
            }.value
        } catch {
            Self.securityLog.error(
                "model-thinking quarantine FAILED: \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        guard !moved.isEmpty else { return }
        Self.securityLog.notice(
            "model-thinking quarantine: \(moved.count, privacy: .public) item(s) re-kinded"
        )
        refreshCounts()
    }

    /// Route the MLX backend's per-turn stats onto the streaming assistant message
    /// (the in-app testing readout). Always records — it's a cheap struct stamp; the
    /// message view decides whether to render it, gated by the Settings toggle.
    private func installGenerationMetricsSink() {
        GenerationMetricsReporter.install { [weak self] metrics in
            Task { @MainActor in self?.chat.recordMetrics(metrics) }
        }
    }

    /// Pre-warm the embedder at launch so the FIRST chat turn isn't slow.
    /// Every turn embeds the query BEFORE retrieval + generation, on the critical
    /// path to the first token (`AgentRAGResponder.answerStreaming`); the MLX
    /// embedder (~600MB) lazy-loads on its first `embed`, so without this the
    /// first question stalls on that cold Metal load before M1K3 even starts
    /// thinking — a chunk of the "TTFT is off on the first reply" feel. One
    /// throwaway embed loads the container + warms the kernels. Idempotent (the
    /// container is cached, so it's a no-op if `reindexIfEmbedderChanged` already
    /// ran), and near-free on the Hashing embedder. Off the main critical path —
    /// it's launch housekeeping, not gated on a turn.
    ///
    /// Signed: Kev + claude-opus-4-8, 2026-06-30, Confidence 0.8 (TTFT first-turn
    /// fix; the cold-embedder-on-critical-path was traced in code, the win is
    /// verify-by-launch via SelfTest). Prior: this file.
    /// Review: Kev + claude-fable-5, 2026-07-11 — MEASURED (ledger 113-4 closed):
    /// SelfTest embedwarm probe ×3 on this M4-class Mac, qwen3-embed 0.6B-4bit —
    /// cold 3927/4004/4122 ms vs warm 15 ms every run ⇒ this warm removes a
    /// ~4.0 s tax from the first turn's TTFT. Runs 2–3 had the OS page cache
    /// warm and still paid ~4 s, so the cost is Metal/container init, not disk
    /// I/O — a cold relaunch pays it every time without this. Confidence 0.95.
    private func warmEmbedderOnLaunch() async {
        // Background work: skip under thermal/low-power pressure (the embedder
        // lazy-loads on the first query anyway, and the thermal-recovery observer
        // re-warms it on cooldown). backgroundWorkAllowed reads ProcessInfo LIVE,
        // not the stale chat-turn coolHead level.
        guard Self.backgroundWorkAllowed() else { return }
        _ = try? await embedder.embed("warm")
    }

    // MARK: - Thermal recovery (Cool Head knob 1: pause background work under heat)

    /// Arm a one-shot cooldown re-trigger: when the Mac's thermal state OR Low
    /// Power Mode changes such that background work is again allowed, re-run the
    /// deferred reindex + warm. Idempotent — only one observer pair is ever live.
    /// Without this, a reindex deferred under heat would wait until the NEXT
    /// launch (stale vectors until then). BOTH signals matter since the 07-13
    /// always-on cut: `backgroundWorkAllowed()` defers on Low Power Mode too, and
    /// battery-saver toggles fire the power notification, not the thermal one —
    /// watching only thermal would strand a battery-saver Mac's deferred work.
    func armThermalRecovery() {
        guard thermalRecoveryObserver == nil else { return }
        let recover: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // All self-gate on backgroundWorkAllowed; re-arm stays a no-op.
                await self.reindexIfEmbedderChanged()
                await self.reindexMemoryGraphIfNeeded()
                await self.warmEmbedderOnLaunch()
                await self.syncSpotlightIndex()
                // The prefix warm's cooldown retry (its hot-skip arms this
                // observer, same as the reindexes) — only once a brain is
                // actually warm to seed from. Idempotent: a cache hit no-ops.
                if case .ready = self.modelLoad {
                    self.warmPersonaPrefixAfterLoad(self.currentMLXProvider)
                }
                // Cooled back down and the work ran → tear the observers down.
                if Self.backgroundWorkAllowed() { self.disarmThermalRecovery() }
            }
        }
        thermalRecoveryObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main,
            using: recover
        )
        powerRecoveryObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main,
            using: recover
        )
    }

    private func disarmThermalRecovery() {
        if let observer = thermalRecoveryObserver {
            NotificationCenter.default.removeObserver(observer)
            thermalRecoveryObserver = nil
        }
        if let observer = powerRecoveryObserver {
            NotificationCenter.default.removeObserver(observer)
            powerRecoveryObserver = nil
        }
    }

    /// The user's self-description (onboarding "you" step). Lives in
    /// knowledge_meta — NEVER in RAG chunks, so it can't be retrieved or
    /// cited; it only rides the persona's About-the-user block.
    nonisolated static var userProfileMetaKey: String {
        "user.profile"
    }

    /// The user's display name as HelloView collected it — a dedicated key so
    /// GreetingCard can greet by name without parsing the free-text profile
    /// blob back apart (the blob is Settings-editable and un-parseable).
    nonisolated static let userDisplayNameKey = "user.displayName"

    /// HelloView's name save. Two stores, deliberately asymmetric:
    /// - the display-name key always updates (it's presentation, cheap to redo);
    /// - the persona profile blob is seeded ONLY when no profile exists yet — a
    ///   re-run overwrite would destroy notes the user added in Settings
    ///   ("About you" owns the blob after first run).
    func saveFirstRunName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: Self.userDisplayNameKey)
        let existing = (try? store.meta(key: Self.userProfileMetaKey)) ?? nil
        if existing?.isEmpty != false {
            saveUserProfile("Name: \(trimmed).")
        }
    }

    /// Persist + apply the profile. Empty input clears it. The persona prefix
    /// cache re-keys off the persona text, so caches rebuild automatically.
    /// Capped at the STORE boundary too (compose soft-trims at render time as
    /// the safety net) — what's persisted is what the model actually sees,
    /// and Settings re-displays the stored value.
    func saveUserProfile(_ text: String?) {
        let trimmed = (text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        let capped = String(trimmed.prefix(M1K3Persona.profileCharacterCap))
        try? store.setMeta(key: Self.userProfileMetaKey, value: capped)
        M1K3Persona.setUserProfile(capped.isEmpty ? nil : capped)
    }

    /// Re-embed the store when the running embedder's vector space doesn't
    /// match the one that produced the stored vectors — e.g. after an mlx-swift
    /// bump changes the embedding kernels. Background, one-time; the Settings
    /// progress row (isReindexing/embeddingStatus) reports it. FTS keeps
    /// serving mid-reindex; vector ranks are briefly mixed-space, acceptable
    /// for a minutes-long one-time migration.
    func reindexIfEmbedderChanged() async {
        // Salted with the EmbeddingText composition version: a composition
        // change (B5 layer 3, title-prefixed chunks) re-embeds the corpus
        // exactly like an embedder swap — mixed composition in one store
        // would compare incompatible vectors forever.
        let current = EmbeddingText.storeFingerprint(embedder: embedder.fingerprint)
        let stored = (try? store.meta(key: KnowledgeStore.embedderFingerprintKey)) ?? nil
        let vectorCount = (try? store.embeddingCount()) ?? 0
        guard EmbedderReindexPolicy.needsReindex(
            stored: stored, current: current, embeddingCount: vectorCount
        ) else {
            // Adopt the marker on fresh/empty stores so the next comparison
            // is against a real value.
            if stored != current {
                try? store.setMeta(key: KnowledgeStore.embedderFingerprintKey, value: current)
            }
            return
        }
        // There IS a full re-embed to do (heavy background work) — defer it under
        // thermal/low-power pressure rather than pile onto a throttling Mac. The
        // marker is NOT adopted, so needsReindex stays true; armThermalRecovery re-runs
        // this the moment the machine cools (no longer "waits until next launch").
        guard Self.backgroundWorkAllowed() else {
            Self.embedLog.notice("reindex deferred — thermal/low-power pressure; retries on cooldown")
            armThermalRecovery()
            return
        }
        guard !isReindexing else { return }
        isReindexing = true
        embeddingStatus = "Updating the index for the new embedder…"
        defer { isReindexing = false }
        Self.embedLog.notice("embedder changed (\(vectorCount) vectors) — reindexing")
        do {
            let count = try await store.reindexEmbeddings(using: embedder, fingerprint: current)
            embeddingStatus = "Reindexed \(count) chunk\(count == 1 ? "" : "s") for the new embedder."
        } catch {
            // Reindex writes atomically — the store still matches the stored
            // marker, so the next launch retries.
            Self.embedLog.error("reindex failed — retries next launch: \(error.localizedDescription, privacy: .public)")
            embeddingStatus = "Couldn’t update the index: \(error.localizedDescription)"
        }
    }

    /// The memory GRAPH's twin of `reindexIfEmbedderChanged` (B5 layer 3,
    /// graph lane, 2026-07-09). Two jobs, in order:
    ///
    /// 1. TITLE BACKFILL (one-time per fact): pre-v2 graph rows carry no title,
    ///    but their corpus twins (written by the same `remember`) do — copy it
    ///    across so the reindex below embeds the composed text. Idempotent and
    ///    cheap; facts without a twin stay bare (their vector is unchanged
    ///    semantics, not a regression).
    /// 2. REINDEX when the salted fingerprint mismatches (production stores
    ///    predate ANY memory-graph fingerprint — nil meta + vectors → the
    ///    policy's deliberate re-embed) OR when the backfill titled anything
    ///    (a titled row with a bare vector would mix compositions).
    ///
    /// Same fingerprint salt as the corpus store: one composition doctrine,
    /// one marker format.
    func reindexMemoryGraphIfNeeded() async {
        guard let memoryStore else { return }
        // Thermal gate FIRST — the backfill persists titles, and a titled row
        // must never outlive the pass without its vector repair (the reviewer's
        // stranding case: backfill lands, reindex deferred, next pass sees
        // nothing to backfill AND a matching fingerprint → mismatch forever).
        // armThermalRecovery re-fires this on cooldown, same as the corpus.
        guard Self.backgroundWorkAllowed() else {
            Self.embedLog.notice("memory-graph pass deferred — thermal/low-power pressure; retries on cooldown")
            armThermalRecovery()
            return
        }
        // Own flag, not `isReindexing`: switchEmbeddings holds isReindexing
        // for its whole body and calls this at its end — sharing the flag
        // would silently skip the graph on every embedder swap.
        guard !isMemoryGraphReindexing else { return }
        isMemoryGraphReindexing = true
        defer { isMemoryGraphReindexing = false }

        // A pending flag from a PRIOR pass = titles were written but the
        // process died before the vector repair — the reindex is still owed
        // even though this pass backfills nothing and the fingerprint matches.
        let owedFromPriorCrash =
            ((try? memoryStore.meta(key: MemoryStore.titleBackfillPendingKey)) ?? nil) != nil
        // Off the main actor: the backfill is 2–3 synchronous GRDB round-trips
        // per untitled row (one-time N+1 by design) — background work, not
        // launch-path UI work. Both stores are Sendable (serialized queues).
        let knowledgeStore = store
        let backfilled = await Task.detached(priority: .utility) {
            Self.backfillMemoryTitles(from: knowledgeStore, into: memoryStore)
        }.value
        let current = EmbeddingText.storeFingerprint(embedder: embedder.fingerprint)
        let stored = (try? memoryStore.meta(key: MemoryStore.embedderFingerprintKey)) ?? nil
        let vectorCount = (try? memoryStore.embeddingCount()) ?? 0
        let policySaysReindex = EmbedderReindexPolicy.needsReindex(
            stored: stored, current: current, embeddingCount: vectorCount
        )
        guard policySaysReindex || ((backfilled > 0 || owedFromPriorCrash) && vectorCount > 0) else {
            if stored != current, vectorCount == 0 {
                // Adopt the marker on fresh/empty graphs. MemoryStore's
                // reindexEmbeddings deliberately DIFFERS from KnowledgeStore's
                // sibling here: it records the fingerprint even with zero rows
                // (pinned by emptyStoreAdoptsMarker) — don't "fix" either to
                // match the other.
                _ = try? await memoryStore.reindexEmbeddings(using: embedder, fingerprint: current)
            }
            return
        }
        do {
            let count = try await memoryStore.reindexEmbeddings(using: embedder, fingerprint: current)
            // Vectors repaired — the crash-recovery flag (set before the first
            // title write) has served its purpose.
            try? memoryStore.deleteMeta(key: MemoryStore.titleBackfillPendingKey)
            Self.embedLog.notice("memory graph reindexed: \(count) fact(s), \(backfilled) title(s) backfilled")
        } catch {
            Self.embedLog.error("memory-graph reindex failed — retries next launch: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Copy corpus-twin titles onto untitled graph facts. Returns how many
    /// rows gained a title. Row-only writes — the caller's reindex owns the
    /// vector repair. Crash-safe: the pending flag lands BEFORE the first
    /// title write and is cleared only after the reindex succeeds, so a kill
    /// anywhere between leaves the flag and the next pass repairs the vectors.
    private nonisolated static func backfillMemoryTitles(
        from knowledgeStore: KnowledgeStore, into memoryStore: MemoryStore
    ) -> Int {
        guard let untitled = try? memoryStore.memoriesWithoutTitle(), !untitled.isEmpty else { return 0 }
        var backfilled = 0
        for memory in untitled {
            let ref = MemoryDistillationCoordinator.factSourceRef(memory.text)
            guard let itemID = try? knowledgeStore.itemID(forSourceRef: ref),
                  let title = (try? knowledgeStore.item(id: itemID))?.title,
                  !title.isEmpty, title != memory.text
            else { continue }
            if backfilled == 0 {
                // First real write of the pass — arm the crash-recovery flag.
                guard (try? memoryStore.setMeta(key: MemoryStore.titleBackfillPendingKey, value: "1")) != nil
                else { continue }
            }
            if (try? memoryStore.setTitle(title, for: memory.id)) != nil {
                backfilled += 1
            }
        }
        return backfilled
    }
}

// MARK: - Recorded-call transcription

extension AppEnvironment {
    /// Download + load the batch transcription model, then process any recording
    /// that's waiting. Opt-in (heavy first download), mirroring `enableWhisperKit`.
    func enableCallTranscription() async {
        guard !isPreparingBatchTranscription, !batchTranscriber.isAvailable else { return }
        isPreparingBatchTranscription = true
        lastCallStatus = "Downloading call-transcription model…"
        do {
            try await batchTranscriber.prepareModel { fraction in
                // Only apply while still preparing — a late hop near 100% must not
                // clobber the terminal status (same race guarded in preloadGemma).
                Task { @MainActor in
                    if self.isPreparingBatchTranscription {
                        self.lastCallStatus = "Downloading call-transcription model… \(Int((fraction * 100).rounded()))%"
                    }
                }
            }
            isPreparingBatchTranscription = false
            // Remember the upgrade so the next launch reloads the batch model instead
            // of reverting to OFF and silently parking the next recorded call.
            UserDefaults.standard.set(true, forKey: Self.callTranscriptionEnabledKey)
            // Process everything that was parked while transcription was off — the
            // just-stopped recording AND any from earlier sessions.
            if await recoverParkedRecordings() == 0 {
                lastCallStatus = "Call transcription ready."
            }
        } catch {
            isPreparingBatchTranscription = false
            lastCallStatus = "Couldn’t load call transcription: \(error.localizedDescription)"
        }
    }

    /// Process recordings that were parked in the durable dir (captured while
    /// transcription wasn't ready — including across a relaunch). If transcription
    /// is available now, transcribe each (then it's removed from the dir); if not,
    /// surface how many are waiting so they're never silently lost.
    /// - Returns: the number of parked recordings found.
    @discardableResult
    func recoverParkedRecordings() async -> Int {
        guard !isRecoveringParked else { return 0 }
        isRecoveringParked = true
        defer { isRecoveringParked = false }
        let listing = (try? FileManager.default.contentsOfDirectory(atPath: recordingsDir.path)) ?? []
        let pending = ParkedRecordings.pending(in: listing)
        guard !pending.isEmpty else { return 0 }
        if batchTranscriber.isAvailable {
            // Serial by design: processRecording's `defer { isTranscribingCall = false }`
            // resets before the next await, so each recording transcribes one at a
            // time (no swamping memory with concurrent jobs).
            for name in pending {
                await processRecording(url: recordingsDir.appendingPathComponent(name))
            }
        } else {
            lastCallStatus = ParkedRecordings.waitingMessage(count: pending.count)
        }
        return pending.count
    }

    /// Reload the batch transcription model on launch when the user enabled it
    /// before and the (shared WhisperKit) model is already on disk — so recorded
    /// calls transcribe every session without re-enabling. Quiet by design: the
    /// bytes are cached (no download) so there's no status flashing, unlike the
    /// explicit `enableCallTranscription` flow. Idempotent + reuses the same
    /// in-flight guard so it can't race a manual enable.
    func restoreCallTranscriptionIfEnabled() async {
        guard CallTranscriptionRestore.shouldRestore(
            wasEnabled: UserDefaults.standard.bool(forKey: Self.callTranscriptionEnabledKey),
            modelDownloaded: batchTranscriber.isModelDownloaded
        ) else { return }
        guard !isPreparingBatchTranscription, !batchTranscriber.isAvailable else { return }
        isPreparingBatchTranscription = true
        defer { isPreparingBatchTranscription = false }
        do {
            try await batchTranscriber.prepareModel { _ in }
            Self.callLog.notice("call transcription restored on launch (model already on disk)")
        } catch {
            Self.callLog.error("call-transcription launch restore failed: \(error, privacy: .public)")
        }
    }

    /// Transcribe a recorded file through the call pipeline, then persist (encrypted)
    /// + index into the knowledge graph — exactly the back half of `importCallTranscript`,
    /// so a recorded call and an imported one land identically.
    func processRecording(url: URL) async {
        guard !isTranscribingCall else { return }
        isTranscribingCall = true
        defer { isTranscribingCall = false }

        lastCallStatus = "Transcribing…"
        let title = "Call \(Self.callTitleFormatter.string(from: Date()))"
        // Stereo-channel diarization attributes speakers when each party is on its
        // own channel; it returns no turns for a mono file, so the pipeline simply
        // leaves the transcript unattributed (no error). FluidAudio (mono) drops in
        // behind the same seam later.
        let pipeline = CallIntelligencePipeline(
            transcriber: batchTranscriber,
            diarizer: StereoChannelDiarizer(),
            summarizer: callSummarizer
        )
        do {
            let session = try await pipeline.process(fileURL: url, title: title, startedAt: Date())
            guard !session.segments.isEmpty else {
                // Transcription RAN and found no speech — a deterministic empty
                // result. Consume the file so it isn't re-transcribed every launch
                // (a thrown failure below keeps it, so transient faults retry).
                consumeRecording(at: url)
                lastCallStatus = "Transcription produced no speech."
                return
            }
            // save() is the COMMIT point: once the call is in the store it's durable,
            // so consume the source recording NOW — never reprocess it into a
            // duplicate. Indexing below is best-effort + isolated: recovery runs early
            // at launch when the embedder may still be cold, and an ingest throw there
            // must NOT undo the save or re-park the .caf (the duplicate-on-relaunch bug
            // the self-test caught). Mirrors the pipeline's own optional/isolated
            // diarizer + summary stages.
            try callPersistence.save(session)
            consumeRecording(at: url)
            refreshCounts()
            var indexed = true
            do {
                try await callIngester.ingest(session)
            } catch {
                indexed = false
                Self.callLog.error("call indexing failed (call saved, not yet searchable): \(error, privacy: .public)")
            }
            lastCallStatus = indexed
                ? "Transcribed “\(title)” — \(session.segments.count) segments, indexed."
                : "Transcribed “\(title)” — \(session.segments.count) segments (indexing deferred)."
        } catch {
            // Left in place ON PURPOSE: a thrown transcribe/save error (NOT indexing)
            // is treated as transient, so the recording stays parked and retries.
            lastCallStatus = "Couldn’t transcribe the call: \(error.localizedDescription)"
        }
    }

    /// A recording that's been fully handled (saved, or ran and found no speech) is
    /// removed from the durable dir and dropped as the pending URL — so it's never
    /// re-processed. Only a THROWN failure skips this (keeping the file for retry).
    private func consumeRecording(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        if lastRecordingURL == url { lastRecordingURL = nil }
    }

    fileprivate static let callTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

// MARK: - Voice input (dictation)

//
// Extracted to a same-file extension (sees the class's private members) to keep
// the main class body under SwiftLint's type_body_length — the established fix in
// this file. Pure UI-driven orchestration over the tested TranscriptionRouter.

extension AppEnvironment {
    /// Tap-to-start / tap-to-stop. On stop (user tap OR the recogniser settling
    /// on a final result) the transcript is sent automatically.
    func toggleDictation() {
        if isListening { stopDictation() } else { startDictation() }
    }

    private func startDictation() {
        guard let provider = transcription.activeProvider else { return }
        // Known-denied grants get the recovery banner up front, not a silent
        // empty listen (`.notDetermined` passes — the system dialog is the ask).
        guard voicePermissionPreflight() else { return }
        dictationTask?.cancel() // belt-and-suspenders: never leave a prior consumer running
        dictationProvider = provider
        liveTranscript = ""
        isListening = true
        avatar.setActivity(.listening)
        do {
            let stream = try provider.startListening()
            dictationTask = Task { @MainActor in
                var accumulator = TranscriptAccumulator()
                for await segment in stream {
                    accumulator.ingest(segment)
                    liveTranscript = accumulator.text
                }
                // A cancelled dictation (the discard button / Escape) must never
                // send — cancelDictation() already reset the surface state.
                guard !Task.isCancelled else { return }
                await finishDictation(text: accumulator.text, confidence: accumulator.confidence)
            }
        } catch {
            // Mic dies mid-session (permission revoked, audio-engine failure) with
            // no UI status otherwise — leave a trail before resetting.
            Self.voiceLog.error("dictation failed: \(error.localizedDescription, privacy: .public)")
            isListening = false
            dictationProvider = nil
            liveTranscript = ""
        }
    }

    /// Ask the active recogniser to stop; the stream then finishes and
    /// `finishDictation` auto-sends.
    private func stopDictation() {
        liveTranscript = "" // clear the ticker on the stop tap, not when the stream drains
        dictationProvider?.stopListening()
    }

    /// Discard an in-flight dictation WITHOUT sending — the bail-out the
    /// tap-to-send mic never offered (a stray dog bark used to leave you one
    /// choice: fire the garble at the model). Cancels the consumer task first
    /// so the drained stream can't reach `finishDictation`'s send.
    func cancelDictation() {
        guard isListening else { return }
        dictationTask?.cancel()
        dictationTask = nil
        dictationProvider?.stopListening()
        dictationProvider = nil
        isListening = false
        liveTranscript = ""
        avatar.resetToIdle()
    }

    private func finishDictation(text: String, confidence: Float?) async {
        isListening = false
        liveTranscript = ""
        dictationProvider = nil
        dictationTask = nil
        // Hygiene-clean the final transcript (repetition / silence hallucinations /
        // whitespace) before it reaches the model — an all-noise dictation becomes "".
        let cleaned = TranscriptSanitizer.clean(text, confidence: confidence)
        // Drop a dictated turn that finished before the brain is ready (a slow
        // first model load) rather than firing it at a still-loading backend.
        guard !cleaned.isEmpty, isReady else {
            avatar.resetToIdle()
            return
        }
        await send(cleaned)
    }
}

// MARK: - Voice output (TTS tier)

//
// Same-file extension (keeps the class body under SwiftLint's type_body_length)
// for the speech-output tier: choosing Built-in vs M1K3 Voice, downloading the
// Kokoro model with progress, and a sample-playback helper for onboarding/Settings.

extension AppEnvironment {
    /// Switch the active TTS tier. Built-in swaps back instantly; M1K3 Voice kicks
    /// the model download (or swaps in immediately if already staged).
    func selectVoiceTier(_ tier: VoiceTier) {
        switch tier {
        case .builtin:
            speech.setProvider(builtinSpeech)
            selectedVoiceTier = .builtin
            UserDefaults.standard.set(VoiceTier.builtin.rawValue, forKey: Self.selectedVoiceTierKey)
            if voiceLoad.isActive { voiceLoad = .idle }
        case .m1k3Voice:
            Task { await prepareM1K3Voice() }
        }
    }

    /// Download + stage the Kokoro model (real progress into `voiceLoad`), then swap
    /// the speech façade to M1K3 Voice. Mirrors `enableWhisperKit`. Idempotent — the
    /// provider returns instantly once the weights are on disk.
    func prepareM1K3Voice() async {
        guard !isPreparingVoice else { return }
        isPreparingVoice = true
        voiceLoad = .progress(0)
        do {
            try await kokoro.prepare { fraction in
                // Only apply while still downloading — guard the late-hop-over-.ready
                // race (same fix as preloadGemma / enableWhisperKit).
                Task { @MainActor in
                    if case .downloading = self.voiceLoad { self.voiceLoad = .progress(fraction) }
                }
            }
            speech.setProvider(kokoro)
            selectedVoiceTier = .m1k3Voice
            UserDefaults.standard.set(VoiceTier.m1k3Voice.rawValue, forKey: Self.selectedVoiceTierKey)
            isPreparingVoice = false
            voiceLoad = .ready
        } catch {
            isPreparingVoice = false
            voiceLoad = .failed(message: error.localizedDescription)
        }
    }

    /// Speak a short sample line in the current voice — the onboarding/Settings
    /// "Hear a sample" affordance.
    func speakSample() async {
        await speech.speak("Hi, I'm M1K3 — but my friends call me Mike!")
    }
}
