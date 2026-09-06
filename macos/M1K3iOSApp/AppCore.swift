//
//  AppCore.swift
//  M1K3iOS / M1K3visionOS — the shared adaptive shell's composition root
//
//  The iOS/visionOS sibling of the macOS `AppEnvironment`: it wires the SAME
//  protocol-seam package graph (`swift test`-covered) into one observable object
//  the SwiftUI screens read. It deliberately does NOT touch the macOS
//  AppEnvironment — that's the shipping product's composition root, AppKit-bound
//  and only tested through the Mac app. Instead this is a fresh, mobile-native
//  root that wires the portable targets (Knowledge, Memory, Inference, MLX, Chat,
//  Agent, AgentTools, Avatar). Everything here is a thin assembly of types the
//  package already tests — no business logic lives in the app target.
//
//  What's wired (Phase A — the spine): KnowledgeStore + hybrid RAG, the temporal
//  MemoryStore, the swappable inference slot (Mini = Apple Foundation Models,
//  Lil = MLX Qwen3-4B), the always-on tool-calling `AgentRAGResponder`, a
//  persisted `ChatSession`, `DocumentIngester`, and the pixel-face avatar.
//  Voice-first mode is wired as of 2026-07-29 (AppCore+Voice: the shared
//  VoiceLoopController over AppleSpeechTranscriber + AVSpeechProvider).
//  NOT wired (Phase B+, device/runtime-gated): the in-app MCP server, call
//  intelligence, Kokoro TTS, WhisperKit. The mobile ladder tops out at Lil
//  (BrainTier.recommended(platform: .mobile)) — iPhones stay on Mini.
//
//  Signed: Kev + claude-opus-4-8, 2026-07-06, Confidence 0.75 (compile-verified
//  for iOS/visionOS; on-device RUN is the Phase-B verify-owed — MLX needs Metal,
//  which the simulator can't run). Prior: Unknown.
//
//  Review: Kev + claude-fable-5.1, 2026-09-03 — voice output goes behind the Mac's SwappableSpeechProvider façade:
//  Built-in stays the default, M1K3 Voice (Kokoro/MLX) is a Settings pick that downloads once (AppCore+VoiceOutput),
//  restored on launch only when already staged (VoiceTierRestore).
//  Review: Kev + claude-fable-5.1, 2026-09-03 — the tool palette goes through the shared ToolPalettePolicy
//  (availability-gated, same rule as the Mac) so both shells derive it from one rule.
//  Review: Kev + claude-fable-5.1, 2026-09-05 — a device with no local brain fronts the paired Mac on its own
//  (after pairing + at launch, MobileBrainMenu.hasLocalBrain). Confidence now 0.85.
//  Review: Kev + claude-fable-5.1, 2026-09-06 — launch restore chains `easedToOfferedMini(afm:)` BEFORE the memory
//  floor: a persisted Mini on a blocked device becomes pocket (and back when AFM returns); below pocket's floor it
//  eases to Mini and the Home-only path takes over. Verified on the 3 GB iPad: pre-floor build eased to pocket,
//  downloaded 632 MB and warmed ("Mini ready"), then died on the first generation (Metal compiler); the floored
//  build launches without touching MLX. Confidence now 0.8.
//  Review: Kev + claude-fable-5.1, 2026-09-06 (2) — `historyBudgetProvider` + a capped `maxTokens` on both MLX
//  provider sites, the Mac's HistoryBudgetPolicy wiring mirrored: pocket's 8k window gets its clamp on the phone
//  too (PR #234 review 6). Confidence now 0.8.
//  Review: Kev + claude-fable-5.1, 2026-09-06 (3) — the restore runs `BrainRestoreConsent` (#237): an eased pick
//  that would download is offered (`pendingBrainDownloadOffer`), not started; staged-ness via LocalModelInventory.
//  Confidence now 0.8.
//

import Foundation
import M1K3Agent
import M1K3AgentTools
import M1K3Avatar
import M1K3BrainLink
import M1K3Chat
import M1K3Inference
import M1K3Knowledge
import M1K3KnowledgeTools
import M1K3Kokoro
import M1K3Memory
import M1K3MemoryChatBridge
import M1K3MLX
import M1K3Voice
import Observation
import os
import SwiftUI

@MainActor
@Observable
final class AppCore {
    // MARK: - Stores & pipeline (all portable package types)

    let store: KnowledgeStore
    /// The temporal memory graph — atomic facts + typed edges, SEPARATE from the
    /// RAG corpus. Best-effort: a hiccup opening it leaves memory read/recall inert.
    let memoryStore: MemoryStore?
    /// Hashing embeddings for v1 (offline, instant, self-consistent vector space).
    /// Semantic MLX embeddings — a ~600 MB download — are a Phase-B follow behind
    /// the same `EmbeddingService` seam. The runtime swap façade
    /// (`SwappableEmbeddingService`) now lives in M1K3Knowledge (shared with the
    /// Mac app), so wiring it here when the MLX embedder lands is a one-liner.
    let embedder: any EmbeddingService
    let ingester: DocumentIngester
    let chat: ChatSession
    /// The pixel-cube companion, shared verbatim with the Mac app (AvatarView).
    let avatar = AvatarController()

    // MARK: - Voice-first mode (system providers; wiring in AppCore+Voice)

    /// Voice OUTPUT, behind the swap façade the Mac uses: Built-in
    /// (AVSpeechSynthesizer) is the first-run default and the swap-back target;
    /// M1K3 Voice (Kokoro on pure MLX) downloads once on pick — see
    /// AppCore+VoiceOutput. The loop and the karaoke callbacks only ever see the
    /// façade, so a tier switch never re-wires them.
    let speech: SwappableSpeechProvider
    let builtinSpeech = AVSpeechProvider()
    let kokoro: KokoroSpeechProvider
    /// Live on-device dictation (SFSpeechRecognizer + AVAudioEngine). On-device
    /// recognition is REQUIRED by the provider — no server fallback, by design.
    let transcriber = AppleSpeechTranscriber()
    /// The live voice-first loop — non-nil while the mode is active (drives the
    /// full-screen VoiceScreen cover). Internal-set: AppCore+Voice owns entry/exit.
    var voiceLoop: VoiceLoopController?
    /// Word-highlight state for the karaoke line in voice mode — the Mac's
    /// SpeechHighlight, cherry-picked verbatim; fed by AVSpeechProvider's live
    /// word ranges (AppCore+Voice.wireSpeechCallbacks).
    let speechHighlight = SpeechHighlight()
    /// Why the loop is parked after an audio interruption (a call, headphones
    /// pulled) — shown in place of the idle caption; cleared on tap-to-talk.
    var voicePauseNote: String?
    /// The chosen TTS tier — restored on launch only when its weights are already
    /// staged (VoiceTierRestore), persisted on pick.
    /// Set only by AppCore+VoiceOutput (cross-file, so not `private(set)`).
    var selectedVoiceTier: VoiceTier = .builtin
    /// M1K3 Voice download/stage state — the Settings progress bar. Set only by
    /// AppCore+VoiceOutput.
    var voiceLoad: ModelLoadState = .idle
    /// The in-flight M1K3 Voice download (AppCore+VoiceOutput) — held so a
    /// Built-in pick mid-download can cancel it; generation-stamped like
    /// `warmGeneration` so a cancel-then-repick can't clear the newer handle.
    var voicePrepareTask: Task<Void, Never>?
    var voicePrepareGeneration = 0
    /// The serialized speak dependency's waiter (AppCore+Voice.speakAndWait).
    var pendingSpeechEnd: CheckedContinuation<Void, Never>?
    /// The enqueue for the chunk being spoken, held so a stop that lands before
    /// it has run can cancel the speak itself (see AppCore+Voice.speakAndWait).
    var pendingSpeak: Task<Void, Never>?
    /// AVAudioSession interruption / route-change / reset observers, installed
    /// for the life of a voice session.
    var audioSessionObservers: [any NSObjectProtocol] = []

    /// The single inference slot the responder holds. Re-pointed on brain switch
    /// (Mini = AFM, Lil = MLX) so the transcript is preserved across a swap.
    private let activeProvider: SwappableInferenceProvider
    private let afm = AppleFoundationModelsProvider()
    private var currentMLX: MLXGemmaProvider?
    private var warmTask: Task<Void, Never>?
    /// Monotonic token: a late-arriving warm progress hop only applies if it still
    /// matches the current generation, so a brain switch mid-warm can't be clobbered
    /// by the abandoned download's callbacks (the Mac AppEnvironment's stale-hop guard).
    private var warmGeneration = 0

    // MARK: - Observable UI state

    private(set) var selectedBrain: BrainTier
    /// Warm-up state for the MLX brain (Lil). Stays `.idle` for Mini (AFM).
    private(set) var brainLoad: ModelLoadState = .idle
    private(set) var indexedItemCount = 0
    private(set) var lastIngestStatus: String?
    /// A transient note about the brain choice (e.g. "Lil runs on a real device"
    /// on the Simulator). Surfaced in Settings under the picker.
    private(set) var brainNote: String?
    /// #237: the tier the launch restore held back because it needs a download
    /// nobody tapped for. The chat hint offers it; accepting is a normal pick.
    private(set) var pendingBrainDownloadOffer: BrainTier?

    // MARK: - Brain at Home (Phase C — the paired Mac's brain over the LAN)

    /// The paired Mac, if any. Metadata only — the PSK lives in the Keychain
    /// (PairedBrainStore's split, mirroring the Mac side).
    private(set) var homeBrain: PairedBrain?
    /// True while the inference slot points at the paired Mac's brain. The
    /// local `selectedBrain` is kept untouched as the tier to return to.
    private(set) var homeBrainActive = false
    /// Device-side pairing persistence (defaults metadata + Keychain PSK).
    let brainLinkStore = PairedBrainStore()

    // MARK: - Persistence keys (shared spelling with the Mac app so a brain

    // choice reads back consistently in the responder's brain-name provider).

    /// `nonisolated` (like the Mac AppEnvironment's keys) so the responder's
    /// @Sendable per-turn closures can read them off the main actor.
    nonisolated static let selectedBrainKey = "selectedBrain"
    /// The history window's reserves — the policy's own figures, shared with the
    /// Mac shell so the two cannot drift.
    nonisolated static let historyReserveTokens = HistoryBudgetPolicy.liveReserveTokens
    nonisolated static let historyGenerationReserveTokens = HistoryBudgetPolicy.liveGenerationReserveTokens
    nonisolated static let hasChosenBrainKey = "hasChosenBrain"
    /// Whether the Home (paired Mac) brain fronts the slot — device-local,
    /// deliberately NOT shared spelling with the Mac (it has no Home tier).
    nonisolated static let homeBrainActiveKey = "brainLink.homeActive"
    nonisolated static let webSearchEnabledKey = "webSearchEnabled"
    /// Shared spelling with the Mac (AppEnvironment.selectedVoiceTierKey).
    nonisolated static let selectedVoiceTierKey = "selectedVoiceTier"
    /// The full-bleed reactive avatar behind chat — default ON; the Settings
    /// toggle is the opt-out (the Mac's avatarDisplay panel/background choice,
    /// collapsed to a switch). Reduce Transparency also disables it, unstored.
    nonisolated static let avatarBackdropKey = "avatarBackdrop"
    /// Memory auto-capture toggle — default ON (matches the Mac). Off = M1K3
    /// never distils durable facts from your chat.
    nonisolated static let memoryAutoCaptureKey = "memoryAutoCapture"
    nonisolated static func memoryAutoCaptureEnabled() -> Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: memoryAutoCaptureKey) == nil
            || defaults.bool(forKey: memoryAutoCaptureKey)
    }

    private static let log = Logger(subsystem: "app.m1k3", category: "ios-core")

    var hasChosenBrain: Bool {
        UserDefaults.standard.bool(forKey: Self.hasChosenBrainKey)
    }

    /// Ready to answer? Mini (AFM) manages its own availability at generate-time;
    /// an MLX brain is ready only once its weights are warm. The Home brain is
    /// always "ready" — the Mac speaks its own availability per turn (etiquette
    /// refusals render as words in the answer, never a blocked send button).
    var isReady: Bool {
        if homeBrainActive { return true }
        switch selectedBrain.backing {
        case .appleFoundationModels: return afm.isAvailable
        case .mlx: return brainLoad == .ready
        }
    }

    /// Physical RAM in GB; the memory floors compare against this.
    static var physicalMemoryGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    }

    /// Whether this device can offer the tier at all (mobile floors: Lil 8 GB).
    static func isSelectableOnThisDevice(_ tier: BrainTier) -> Bool {
        tier.isSelectable(forPhysicalMemoryGB: physicalMemoryGB, platform: .mobile)
    }

    /// MLX needs a real Metal GPU. The iOS/visionOS **Simulator has none**, and
    /// merely SETTING MLX's cache limit force-initialises the Metal device, which
    /// aborts (`mlx::core::metal::Device` → `std::__libcpp_verbose_abort`). So on
    /// the Simulator we never touch MLX at all: Mini (Apple Foundation Models) is
    /// the only brain, and the memory budget is skipped. A real device (proven on
    /// iPhone 17 Pro) runs the full Mini + Lil ladder. Verified: the crash stack
    /// bottomed out at `MLXMemoryBudget.applyOnce()` from `AppCore.init`.
    static let mlxAvailable: Bool = {
        #if targetEnvironment(simulator)
            return false
        #else
            return true
        #endif
    }()

    init() throws {
        // Voice output starts on Built-in; M1K3 Voice is restored below only
        // when it was chosen AND is already on disk. Constructing the Kokoro
        // provider touches no MLX (safe on the Simulator) — prepare() does.
        speech = SwappableSpeechProvider(builtinSpeech)
        kokoro = KokoroSpeechProvider()

        // Same launch hygiene the Mac shell does, through the same shared call
        // (issue #85 makes a mid-conversation kill a real scenario here).
        VoiceModeDefaults.resetAtLaunch()

        // Bound the process-global MLX Metal cache before ANY MLX work (4 GB mobile
        // ceiling). Skipped on the Simulator — see `mlxAvailable`; touching MLX there
        // aborts the process.
        if Self.mlxAvailable {
            MLXMemoryBudget.applyOnce()
        }

        let base = try Self.appSupportDirectory()
        store = try KnowledgeStore(path: base.appendingPathComponent("knowledge.sqlite").path)
        memoryStore = try? MemoryStore(path: base.appendingPathComponent("memory.sqlite").path)

        // Hashing embeddings by default — no ~600 MB embedder download on the
        // first-run critical path.
        let baseEmbedder = HashingEmbeddingService()
        embedder = baseEmbedder
        ingester = DocumentIngester(store: store, embedder: baseEmbedder)

        // Restore the chosen brain (default Mini). Decode via init(persisted:) so a
        // stale "huge" migrates to Big — though the mobile ladder never offers Big.
        // On the Simulator, an MLX pick falls back to Mini for this launch (the
        // persisted choice is untouched, so a real device honours it).
        // A persisted pick below its mobile memory floor eases to Mini — the
        // crash-loop breaker (#227): Lil on a 3 GB iPad was killed mid-load and
        // every relaunch walked straight back into the same wall.
        let storedBrainRaw = UserDefaults.standard.string(forKey: Self.selectedBrainKey)
        // Order matters: first the Mini this device can run (a blocked device's
        // Mini is pocket — LFM2 — and back once Apple Intelligence returns), THEN
        // the memory floor, so a pocket below its 4 GB floor eases to Mini and
        // the Home-only path above takes over (#230) instead of a doomed load.
        // #237: an eased pick that would download waits for a tap — the chat's
        // readiness hint carries the offer; accepting goes through selectBrain.
        // Consent runs on the Apple-Intelligence axis only, BEFORE the memory
        // floor (same order as the Mac; a pocket below its floor still eases to Mini).
        let persisted = storedBrainRaw.flatMap(BrainTier.init(persisted:)) ?? .mini
        let inventory = LocalModelInventory()
        let afmEased: BrainTier
        switch BrainRestoreConsent.resolve(
            persisted: persisted,
            eased: persisted.easedToOfferedMini(afm: afm.availabilityState),
            staged: { tier in tier.mlxModelID.map { inventory.isInstalled(modelID: $0) } ?? false }
        ) {
        case let .warm(tier):
            afmEased = tier
        case let .askFirst(offer, keep):
            afmEased = keep
            // The OFFER must clear the mobile floor too — a 3 GB A12 must never be
            // invited to download a pocket it can't load (PR #239 review); it stays
            // on Mini and the Home-only path (#230/#231) takes over as before.
            if BrainTier.selectableOrEased(offer, forPhysicalMemoryGB: Self.physicalMemoryGB, platform: .mobile) == offer {
                pendingBrainDownloadOffer = offer
                Self.log.notice("restore: \(offer.rawValue, privacy: .public) needs a download — offered, not started (#237)")
            }
        }
        let restored = BrainTier.selectableOrEased(
            afmEased, forPhysicalMemoryGB: Self.physicalMemoryGB, platform: .mobile
        )
        // Persist the eased pick (the Mac's restore does the same): makeResponder's
        // brain-name / thinking / grounding-budget closures read the KEY, not
        // `selectedBrain` — without this they would size prompts for Lil while
        // Mini answers (#228 review).
        if let storedBrainRaw, storedBrainRaw != restored.rawValue {
            UserDefaults.standard.set(restored.rawValue, forKey: Self.selectedBrainKey)
        }
        let brain = (restored.mlxModelID != nil && !Self.mlxAvailable) ? .mini : restored
        selectedBrain = brain

        // Build the inference slot on the chosen brain's backend. Mini uses AFM
        // directly; an MLX brain starts on a provider that's warmed below.
        let initialBackend: any InferenceProvider
        if let modelID = brain.mlxModelID, Self.mlxAvailable {
            let mlx = MLXGemmaProvider(modelID: modelID, maxTokens: Self.generationCap(for: brain))
            currentMLX = mlx
            initialBackend = mlx
        } else {
            initialBackend = afm
        }
        let slot = SwappableInferenceProvider(initialBackend)
        activeProvider = slot

        let responder = Self.makeResponder(store: store, embedder: baseEmbedder, provider: slot)
        let history = try? GRDBChatHistoryStore(
            path: base.appendingPathComponent("chat-history.sqlite").path
        )
        // Memory auto-capture: distil durable facts from chat into the corpus AND
        // mirror them into the temporal graph (via the shared M1K3MemoryChatBridge
        // adapter). Reuses the SAME baseEmbedder recall queries with, so dedup +
        // graph-node vectors stay in one space (hashing for now; the MLX embedder
        // swap in Phase B must be passed here too). Off if the user opts out.
        chat = ChatSession(
            responder: responder,
            history: history,
            titler: ProviderConversationTitler(provider: slot),
            distillation: Self.makeMemoryDistillation(
                store: store,
                embedder: baseEmbedder,
                ingester: ingester,
                fallback: slot,
                graph: memoryStore.map { DistilledFactGraphAdapter(store: $0) as any DistilledFactGraphWriting }
            ),
            autoCaptureEnabled: { Self.memoryAutoCaptureEnabled() }
        )

        refreshCounts()
        // Brain at Home: restore a paired Mac, and re-point the slot at it if
        // Home was fronting when the app last ran.
        homeBrain = brainLinkStore.load()
        // Home fronts when it was chosen — or when nothing local CAN front (#230's
        // Home-only half: a persisted Mini on an AFM-ineligible device would sit
        // unready forever).
        if homeBrain != nil, UserDefaults.standard.bool(forKey: Self.homeBrainActiveKey) || !brainMenu.hasLocalBrain {
            activateHomeBrain()
        }
        // Cheap + synchronous (registration only) — see AppCore+MetricKit.swift.
        startMetricKitCollection()
        // Speech lifecycle → avatar speaking state + the voice loop's completion
        // signal (speechDidEnd). One-time wiring, like the Mac's.
        wireSpeechCallbacks()
        // Restore M1K3 Voice only if it was chosen AND already staged — never a
        // silent ~354 MB re-download on launch (VoiceTierRestore, pinned). A
        // chosen-but-purged voice shows as Built-in until picked again. Never on
        // the Simulator: Kokoro's MLX preload would abort the process.
        let persistedVoice = VoiceTierRestore.restoredTier(
            persisted: UserDefaults.standard.string(forKey: Self.selectedVoiceTierKey)
        )
        if Self.neuralVoiceAvailable,
           VoiceTierRestore.shouldRestore(selected: persistedVoice, modelStaged: kokoro.isModelStaged)
        {
            selectedVoiceTier = .m1k3Voice
            prepareM1K3Voice()
        }
        // Warm a restored MLX brain so it's ready to answer (Mini needs nothing;
        // never on the Simulator, where MLX aborts). Not when Home is fronting —
        // the slot is already pointed at the paired Mac; warming local MLX would
        // swap it away right after activateHomeBrain() above set it.
        if brain.mlxModelID != nil, Self.mlxAvailable, !homeBrainActive {
            warmSelectedBrain()
        }
    }

    // MARK: - Brain selection

    /// Choose a brain. Mini re-points the slot at AFM instantly; an MLX brain
    /// warms its weights (streaming download progress into `brainLoad`) and swaps
    /// in when ready. The chat transcript is preserved (the slot is swapped, not
    /// the responder rebuilt).
    /// Accept the launch offer (#237): the tap this download was waiting for.
    func acceptPendingBrainDownloadOffer() {
        guard let offer = pendingBrainDownloadOffer else { return }
        selectBrain(offer)
    }

    func selectBrain(_ tier: BrainTier) {
        // An explicit pick always wins over a restore-time offer (#237).
        pendingBrainDownloadOffer = nil
        // Simulator: MLX can't run (no Metal GPU — touching it aborts). Record the
        // note and stay on Mini so chat still works; a real device runs Lil.
        // Both refusals fall back to Mini THROUGH this same function, whose
        // first act is `brainNote = nil` — so the note is written AFTER the
        // recursive call returns, or it is wiped before SwiftUI ever sees it
        // (#228 review; the Simulator branch had the same dead note).
        if tier.mlxModelID != nil, !Self.mlxAvailable {
            selectBrain(.mini)
            brainNote = "\(tier.displayName) runs on a real device — the Simulator has no GPU for MLX. Staying on Mini."
            return
        }
        // Below the tier's memory floor the load cannot succeed — iOS kills it
        // (#227). The rows render locked; this is the belt for a stale tap.
        if !Self.isSelectableOnThisDevice(tier), let floor = tier.minimumPhysicalMemoryGB(platform: .mobile) {
            selectBrain(.mini)
            brainNote = floor.isFinite
                ? "\(tier.displayName) needs \(Int(floor)) GB of memory — this device has "
                + "\(Int(Self.physicalMemoryGB.rounded(.down))) GB. Staying on Mini."
                : "\(tier.displayName) doesn't run on this device. Staying on Mini."
            return
        }
        brainNote = nil

        // Leaving the Home brain: the slot currently points at the Mac, so the
        // no-op guard below MUST NOT fire even for the same settled local tier —
        // the whole point of this call is re-pointing the slot at local compute.
        let leavingHome = homeBrainActive
        if leavingHome {
            homeBrainActive = false
            UserDefaults.standard.set(false, forKey: Self.homeBrainActiveKey)
        }

        // No-op guard (the Mac AppEnvironment's fix): re-selecting the SAME,
        // already-settled brain would tear down a warm KV/persona cache and repay a
        // multi-GB load for nothing. Re-tapping Mini when already on Mini is also a
        // no-op. A switch that's mid-warm still falls through (lets the user cancel).
        if tier == selectedBrain, !leavingHome {
            switch tier.mlxModelID {
            case nil where brainLoad == .idle:
                return
            case let modelID? where brainLoad == .ready && currentMLX?.modelIdentifier == modelID:
                return
            default:
                break
            }
        }

        selectedBrain = tier
        UserDefaults.standard.set(tier.rawValue, forKey: Self.selectedBrainKey)
        // The first-run gate (hasChosenBrainKey) is written by the onboarding
        // completion closure (RootView), NOT here: the no-op guard above can
        // early-return before this line (picking Mini — the default AND the
        // recommended tier — while idle), so a gate write here would never fire
        // for the recommended brain and onboarding would repeat on every launch.
        // The onDone closure is the sole gate writer, mirroring the Mac contract.

        warmTask?.cancel()
        warmGeneration += 1 // invalidate any in-flight warm's progress hops
        if tier.mlxModelID == nil {
            // Switching to Mini: release the MLX weights we were holding so the
            // Metal-backed persona-KV allocation doesn't fight the mobile budget.
            currentMLX?.releaseMemory()
            currentMLX = nil
            activeProvider.setProvider(afm)
            brainLoad = .idle
        } else {
            warmSelectedBrain()
        }
    }

    // MARK: - Brain at Home selection

    /// Point the inference slot at the paired Mac's brain. `selectedBrain`
    /// stays untouched — it is the local tier a later selectBrain returns to.
    func selectHomeBrain() {
        guard homeBrain != nil, !homeBrainActive else { return }
        activateHomeBrain()
        if homeBrainActive {
            UserDefaults.standard.set(true, forKey: Self.homeBrainActiveKey)
        }
    }

    /// A fresh pairing succeeded: persist it and surface it in the UI.
    /// Returns false when the Keychain write failed (the pairing is not kept).
    func adoptPairedBrain(_ brain: PairedBrain, key: Data) -> Bool {
        do {
            try brainLinkStore.save(brain, key: key)
        } catch {
            Self.log.error("brain link: keychain save failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        homeBrain = brain
        // A device with no local brain of its own paired for one reason: front the
        // Mac now, don't leave it on an unrunnable Mini behind a "Choose Home" note.
        if !brainMenu.hasLocalBrain { selectHomeBrain() }
        return true // the pairing screen reads homeBrainActive for its copy; a failed activation left brainNote
    }

    /// Forget the paired Mac (client side): key + metadata gone; if Home was
    /// fronting, the slot returns to the local tier. The Mac's own paired-
    /// devices list is cleaned up there (revoke) — pairing is two-sided.
    func forgetHomeBrain() {
        brainLinkStore.forget()
        homeBrain = nil
        if homeBrainActive {
            selectBrain(selectedBrain) // leavingHome path re-points the slot
        }
    }

    private func activateHomeBrain() {
        guard let brain = homeBrain, let credential = brainLinkStore.credential() else {
            // Metadata without a Keychain row (restore/migration edge): honest
            // note, never a half-paired ghost.
            brainNote = "This device’s pairing key is missing — pair with your Mac again."
            return
        }
        warmTask?.cancel()
        warmGeneration += 1
        // Release local MLX weights — the decode is the Mac's while Home
        // fronts, and holding multi-GB weights idle fights the mobile budget.
        currentMLX?.releaseMemory()
        currentMLX = nil
        brainLoad = .idle
        let store = brainLinkStore
        let provider = HomeBrainProvider(
            brain: brain,
            key: credential.key,
            onBrainUpdate: { [weak self] updated in
                store.update(updated)
                Task { @MainActor [weak self] in self?.homeBrain = updated }
            }
        )
        activeProvider.setProvider(provider)
        homeBrainActive = true
        brainNote = nil
    }

    /// The live decode cap for an MLX tier — 2048 where the window is a hard
    /// budget (pocket; Big never runs here), the provider default elsewhere.
    nonisolated static func generationCap(for tier: BrainTier) -> Int {
        HistoryBudgetPolicy.generationTokenCap(for: tier, defaultCap: MLXGemmaProvider.defaultMaxTokens)
    }

    private func warmSelectedBrain() {
        guard let modelID = selectedBrain.mlxModelID else { return }
        let tierName = selectedBrain.displayName
        warmGeneration += 1
        let generation = warmGeneration
        warmTask = Task { [weak self] in
            guard let self, generation == warmGeneration else { return }
            brainLoad = .preparing
            // Reuse the provider already built for this exact model (cold launch made
            // one as the slot's initial backend); only build fresh on a model change,
            // releasing the outgoing weights first — never leak two Metal instances.
            let mlx: MLXGemmaProvider
            if let existing = currentMLX, existing.modelIdentifier == modelID {
                mlx = existing
            } else {
                currentMLX?.releaseMemory()
                mlx = MLXGemmaProvider(modelID: modelID, maxTokens: Self.generationCap(for: selectedBrain))
            }
            do {
                try await mlx.prepare { fraction in
                    Task { @MainActor [weak self] in
                        guard let self, generation == warmGeneration else { return }
                        brainLoad = .progress(fraction)
                    }
                }
                guard generation == warmGeneration else {
                    // A switch superseded this warm mid-prepare. Release the freshly
                    // built weights we're abandoning (unless they became the active
                    // provider) so their Metal buffers are reclaimed now, not left
                    // for the next MLX reclaim — the Mac releases oldMLX synchronously.
                    if mlx !== currentMLX { mlx.releaseMemory() }
                    return
                }
                currentMLX = mlx
                activeProvider.setProvider(mlx)
                brainLoad = .ready
                Self.log.notice("brain warm: \(tierName, privacy: .public) ready")
            } catch {
                if mlx !== currentMLX { mlx.releaseMemory() }
                guard generation == warmGeneration else { return }
                brainLoad = .failed(message: error.localizedDescription)
                Self.log.error("brain warm failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Background lifecycle (iOS jetsam hygiene)

    /// Shed the multi-GB MLX weights when backgrounded. Unlike macOS (no per-app
    /// jetsam), iOS aggressively reclaims a backgrounded process sitting on GBs of
    /// Metal buffers — so we release now and re-warm on return, rather than being
    /// killed and cold-booted. Falls back to Mini (AFM) so a brief foreground still
    /// serves chat while Lil re-warms. Cheap when already on Mini (currentMLX nil).
    /// Only call on a true `.background` transition — NOT `.inactive` (a notification
    /// banner / Control Center), which must not churn the model.
    ///
    /// Gated on `.ready`, NOT merely `currentMLX != nil`: at cold launch the slot's
    /// provider is assigned BEFORE its first load finishes, and the underlying
    /// SingleFlightLoader keeps running through Task cancellation (by design). If we
    /// shed mid-load we couldn't actually stop that allocation, and nilling
    /// currentMLX would make warmForForeground build a SECOND provider racing the
    /// first on the same cache (review catch). So mid-load we leave it be — only a
    /// fully-warm brain holds the reclaimable buffers this is here to shed.
    func releaseForBackground() {
        guard brainLoad == .ready, currentMLX != nil else { return }
        warmTask?.cancel()
        warmGeneration += 1 // invalidate any in-flight warm's progress hops
        currentMLX?.releaseMemory()
        currentMLX = nil
        activeProvider.setProvider(afm)
        brainLoad = .idle
        Self.log.notice("brain shed for background; will re-warm on foreground")
    }

    /// Re-warm the chosen MLX brain if it was shed while backgrounded. No-op when
    /// Mini is the choice or the brain is already warm/warming.
    ///
    /// The `.idle` guard is deliberate: a brain that FAILED to warm (`.failed` — a
    /// gated repo, a full disk, unavailable weights) is NOT retried by a
    /// background→foreground bounce, only by an explicit shed (`.idle` via
    /// `releaseForBackground`) or a user re-selection. Retrying a persistent failure
    /// on every app-switch would be a retry-storm; the failure surfaces once and stays.
    func warmForForeground() {
        // Home brain fronting: the slot points at the paired Mac, and
        // `selectedBrain` is only the LOCAL fallback tier. Warming it here would
        // swap the slot to local MLX — silently dropping the user off Home on
        // every app-switch. Leave the slot on Home.
        guard !homeBrainActive else { return }
        guard selectedBrain.mlxModelID != nil, currentMLX == nil, brainLoad == .idle else { return }
        warmSelectedBrain()
    }

    /// Whether Apple Intelligence (Mini) can serve on this device right now —
    /// drives the onboarding / settings availability hint.
    var miniAvailability: AFMAvailability {
        afm.availabilityState
    }

    /// The brains this device may list (onboarding + Settings): Mini only where
    /// Apple Intelligence can run, Lil only above its mobile floor, Brain at Home
    /// always — the pure table in MobileBrainMenu.
    var brainMenu: MobileBrainMenu {
        MobileBrainMenu.resolve(afm: miniAvailability, physicalMemoryGB: Self.physicalMemoryGB, active: selectedBrain)
    }

    /// Titles of the newest live memories, for the blank-canvas chips. Empty when
    /// the store is absent or nothing has a title yet.
    func recentMemoryTitles(limit: Int = 4) -> [String] {
        guard let memoryStore, let memories = try? memoryStore.allMemories(limit: 40) else { return [] }
        // allMemories is already newest-first.
        return memories
            .compactMap(\.title)
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Send (drives the avatar around ChatSession's streaming send)

    func send(_ text: String) async {
        guard isReady else { return }
        avatar.setActivity(.thinking)
        await chat.send(text)
        if case .failed? = chat.messages.last?.status {
            avatar.setActivity(.error)
        } else {
            avatar.setEmotion(.happy)
            avatar.resetToIdle()
        }
    }

    // MARK: - Documents

    /// Ingest a user-picked file (PDF or UTF-8 text) into the RAG store.
    func ingest(url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let title = url.deletingPathExtension().lastPathComponent
        do {
            let result: DocumentIngester.IngestResult
            if url.pathExtension.lowercased() == "pdf" {
                let data = try Data(contentsOf: url)
                result = try await ingester.ingestPDF(title: title, data: data, sourceRef: url.absoluteString)
            } else {
                let content = try String(contentsOf: url, encoding: .utf8)
                result = try await ingester.ingest(title: title, text: content, sourceRef: url.absoluteString)
            }
            let dedup = result.wasDeduped ? " (already indexed)" : ""
            // A 0-chunk ingest indexed nothing searchable — say so, don't imply success.
            lastIngestStatus = result.chunkCount == 0
                ? "“\(title)” had no indexable text."
                : "Indexed “\(title)” — \(result.chunkCount) chunks\(dedup)."
            refreshCounts()
        } catch {
            lastIngestStatus = "Couldn’t index “\(title)”: \(error.localizedDescription)"
        }
        scheduleIngestStatusClear()
    }

    /// Auto-dismiss the ingest banner so it isn't a permanent fixture on the
    /// Documents tab — clears only if the status hasn't since been replaced.
    private func scheduleIngestStatusClear() {
        let status = lastIngestStatus
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self, lastIngestStatus == status else { return }
            lastIngestStatus = nil
        }
    }

    func documents(limit: Int = 200) -> [KnowledgeItem] {
        (try? store.allItems(limit: limit)) ?? []
    }

    func deleteDocument(id: UUID) {
        _ = try? store.deleteItem(id: id)
        refreshCounts()
    }

    private func refreshCounts() {
        indexedItemCount = (try? store.itemCount()) ?? 0
    }

    // MARK: - Responder factory (the iOS mirror of makeAgentResponder — simpler:

    // no CoolHead/voice-mode plumbing (defaults safely); the history budget + decode cap ARE wired (PR #234))

    private static func makeResponder(
        store: KnowledgeStore,
        embedder: any EmbeddingService,
        provider: any InferenceProvider
    ) -> any RAGResponding {
        let sourceCollector = ToolSourceCollector()
        return AgentRAGResponder(
            store: store,
            embedder: embedder,
            provider: provider,
            toolsProvider: {
                var tools: [any AgentTool] = [
                    DateTimeTool(),
                    SystemStatusTool(),
                    SearchKnowledgeTool(
                        store: store,
                        embedder: embedder,
                        onHits: { hits in sourceCollector.record(hits) }
                    ),
                    ListDocumentsTool(store: store),
                    GetDocumentTool(store: store),
                ]
                let defaults = UserDefaults.standard
                let webAllowed = defaults.object(forKey: Self.webSearchEnabledKey) == nil
                    || defaults.bool(forKey: Self.webSearchEnabledKey)
                if webAllowed {
                    tools.insert(WikipediaTool(), at: 0)
                    tools.insert(FetchPageTool(), at: 0)
                    let deepReader = FetchPageTool(fetcher: URLSessionHTTPFetcher(timeout: 8))
                    tools.insert(WebSearchTool(deepReader: deepReader), at: 0)
                }
                // Same availability rule as the Mac (ToolPalettePolicy): the
                // knowledge tools need a corpus, the web trio needs the toggle.
                // This shell offers no bigger brain and no battery tool.
                return ToolPalettePolicy.filter(tools, availability: .init(
                    corpusHasItems: ToolPalettePolicy.corpusHasItems(count: try? store.itemCount()),
                    webAllowed: webAllowed,
                    deepBrainAvailable: false,
                    // Inert until a battery tool is ever wired into this
                    // palette (none is today); true because the phone has one.
                    hasBattery: true
                ))
            },
            sourceCollector: sourceCollector,
            brainNameProvider: {
                let raw = UserDefaults.standard.string(forKey: Self.selectedBrainKey) ?? ""
                return BrainTier(persisted: raw)?.displayName ?? ""
            },
            fastThinkingProvider: {
                let raw = UserDefaults.standard.string(forKey: Self.selectedBrainKey) ?? ""
                return BrainTier(persisted: raw)?.prefersFastThinking ?? false
            },
            historyBudgetProvider: {
                // The Mac's brain-aware replay window, mirrored (PR #234 review 6):
                // pocket's 8k window is a HARD budget on a 4 GB phone — the
                // tier-blind default (8000 chars) plus an uncapped decode could
                // ask its unbounded KV cache for more than the window the 3.5 GB
                // floor was measured against. Read fresh each turn (hot-swap).
                let raw = UserDefaults.standard.string(forKey: Self.selectedBrainKey) ?? ""
                return HistoryBudgetPolicy.budget(
                    for: BrainTier(persisted: raw),
                    reservedTokens: Self.historyReserveTokens,
                    generationTokens: Self.historyGenerationReserveTokens
                )
            },
            groundingBudgetProvider: {
                // This shell had NO budget provider at all until 2026-08-13, so
                // every tier — including Mini, the mobile first-run default —
                // ran the 1100-token figure derived for Big's 8192-token window.
                // That is PR #101's fix, which never crossed to mobile.
                //
                // A spoken turn tightens again: prefill is paid in full before
                // the first token exists, at a measured 1.71 ms per prompt token
                // (Lil, live path), and it lands directly on time-to-first-audio.
                let defaults = UserDefaults.standard
                let raw = defaults.string(forKey: Self.selectedBrainKey) ?? ""
                return GroundingBudgetPolicy.tokens(
                    for: BrainTier(persisted: raw),
                    spoken: defaults.bool(forKey: VoiceModeDefaults.activeKey)
                )
            }
        )
    }

    // MARK: - Memory distillation factory (the iOS mirror of the Mac's

    // makeMemoryDistillation — AFM distils, the corpus is source of truth, the
    // graph adapter mirrors facts into the temporal graph best-effort)

    private static func makeMemoryDistillation(
        store: KnowledgeStore,
        embedder: any EmbeddingService,
        ingester: DocumentIngester,
        fallback: any InferenceProvider,
        graph: (any DistilledFactGraphWriting)?
    ) -> MemoryDistillationCoordinator {
        MemoryDistillationCoordinator(
            distiller: ProviderMemoryDistiller(
                primary: AppleFoundationModelsProvider(instructions: { MemoryDistillationPrompt.instructions }),
                fallback: fallback
            ),
            ingester: ingester,
            store: store,
            embedder: embedder,
            graph: graph
        )
    }

    // MARK: - Container path

    /// The app's Application Support directory (inside the iOS/visionOS sandbox
    /// container — no `homeDirectoryForCurrentUser`, which is macOS-only).
    private static func appSupportDirectory() throws -> URL {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("M1K3", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
