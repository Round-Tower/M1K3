//
//  AppEnvironment+Downloads.swift
//  M1K3App
//
//  The shell half of Settings > Brains & downloads: it gathers the facts the pure
//  `DownloadCatalogue` needs (what is on disk, what is loading, what is in use) and runs
//  the three verbs — Download, Cancel, Remove — over the six downloaders that already
//  exist, without a seventh way to fetch anything.
//
//    Download   brains  → `BrainWeightsFetcher` (cancellable, no brain switch), wrapped in
//                          `withRetry` so Hub's wrapped timeouts retry (#557)
//               memory  → `switchEmbeddings(toMLX: true)` as it was; progress is shown
//               ears    → `enableWhisperKit()`; real fraction while the model downloads
//               voice   → `prepareM1K3Voice()` (which also selects M1K3 Voice on arrival)
//    Cancel     brains (manager fetch, or the background upgrade fetch) and the voice.
//               NOT the embedder or WhisperKit (opaque single calls) and NOT a foreground
//               `selectBrain` download (SingleFlightLoader keeps it alive): those rows say so.
//    Remove     brains → `LocalModelInventory.remove`; memory → the same over the embedder's
//               Documents/huggingface root; voice → `removeStagedModel()`; ears → the variant's
//               folder. Never offered for an in-use item (the catalogue strips it) and
//               re-checked here, so a stale button cannot delete what is serving.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.65 (glue over tested pure parts;
//  every verb is verify-by-launch: download, cancel mid-fetch and remove each need the app).
//  Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-11 (pre-push review fold) — B2 in-use through `DownloadUsePolicy`; B3 `removing`;
//  B4 complete-vs-partial scan; B5 transition-only refresh with a generation counter (AFM and the retired-folder walk off
//  the hot path); B6 semantic-memory guards; N1 `scanned`; N2/N3 remove ordering; N5 a failed selected brain retries.
//  Confidence 0.65 (verify-by-launch).
//  Review: Kev + claude-opus-5.5, 2026-10-11 (PR 2b) — `offersSemanticMemory(alongside:)` and
//  `semanticMemorySizeLabel`: the one seam the picker and the upgrade card ask for "Also get semantic
//  memory" (`SemanticMemoryOffer`). Confidence 0.8.
//  Review: Kev + claude-opus-5.5, 2026-10-11 (pre-push review fold) — O1 the semantic-memory QUEUE (`requestSemanticMemory`,
//  `watchSemanticQueue`: the surfaces only request; the embedder starts when `SemanticMemoryQueue.shouldStartNow` says the
//  brain, the chat, the re-index and the heat are all clear, retried on every observed transition); O2/O3 the offer gate;
//  O4 the toggle's reserved slot + size fallback; K1 the voice refreshes on completion; K2 `DownloadStatusStore`, the
//  tick-free statuses the glass-hosted kit card reads; K5 `startDownload` says whether it began. Confidence 0.7 (the
//  retry loop and the ordering of two real downloads are verify-by-launch).
//  Review: Kev + claude-opus-5.5, 2026-10-11 (#570 bot fold) — `settleSemanticQueue`: a start or a drop now disarms the
//  watch and cancels the heat nudge, so a retry after a drop is evaluated at once (both passes flagged the stuck
//  `semanticWatchArmed`); the any-brain-fetch hold is documented as intended. Confidence 0.75.

import Foundation
import M1K3Inference
import M1K3MLX
import M1K3Voice
import M1K3WhisperKit
import os

/// What the manager remembers between renders. Observable so the pane repaints on progress.
@MainActor @Observable
final class DownloadsLedger {
    /// Items found COMPLETE on disk by the last `refreshDownloads()`.
    var installed: Set<DownloadKind> = []
    /// Items with some bytes on disk but not all (a cancelled or interrupted fetch).
    var partial: Set<DownloadKind> = []
    /// False until the first scan lands, so no row flashes "Download" for something unread (N1).
    var scanned = false
    /// Removals in flight (B3): busy, not startable, not loadable.
    var removing: Set<DownloadKind> = []
    /// Newest-wins stamp for `refreshDownloads` results.
    @ObservationIgnored var refreshGeneration = 0
    /// Fraction of each in-flight MANAGER brain fetch.
    var brainFetch: [DownloadKind: Double] = [:]
    var failures: [DownloadKind: String] = [:]
    /// True while `switchEmbeddings(toMLX: true)` runs; `embedderFraction` is its download tick.
    var embedderSwitching = false
    var embedderFraction: Double?
    /// Apple Intelligence state, read off the main actor (it is an AFM daemon round-trip).
    var afm: AFMAvailability = .available
    @ObservationIgnored var brainTasks: [DownloadKind: Task<Void, Never>] = [:]
    /// A requested "Also get semantic memory" waiting for its turn (see `SemanticMemoryQueue`).
    var pendingSemanticMemory: PendingSemanticMemory?
    /// Bumped by the heat-retry timer so the queue's observation re-evaluates (heat is not observable).
    var semanticQueueTick = 0
    /// One live observation of the queue at a time.
    @ObservationIgnored var semanticWatchArmed = false
    @ObservationIgnored var semanticRetryTask: Task<Void, Never>?
}

/// A queued semantic-memory request: the brain it rides with, or nil when nothing in particular (Settings, the kit).
struct PendingSemanticMemory: Equatable {
    var brain: BrainTier?
}

/// The statuses of every download WITHOUT their fractions, for surfaces that must not repaint on a tick (the
/// Liquid Glass kit card: a tick that re-evaluates or reflows glass is the #566 layout-crash class). It re-derives
/// the catalogue under observation tracking but publishes only when the PHASE changes (`DownloadItem.phaseOnly`),
/// so a reader of `items` is invalidated on transitions, never per progress tick. Live fractions are read only
/// off the glass, from `AppEnvironment.downloadItems`.
@MainActor @Observable
final class DownloadStatusStore {
    private(set) var items: [DownloadItem] = []
    @ObservationIgnored private var source: (@MainActor () -> [DownloadItem])?
    @ObservationIgnored private var generation = 0

    /// Begin publishing (idempotent per call: a newer start supersedes an older loop).
    func start(_ source: @escaping @MainActor () -> [DownloadItem]) {
        generation += 1
        self.source = source
        track(generation)
    }

    func stop() {
        generation += 1
        source = nil
    }

    private func track(_ generation: Int) {
        guard generation == self.generation, let source else { return }
        let fresh = withObservationTracking {
            source().map(\.phaseOnly)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.track(generation) }
        }
        if fresh != items { items = fresh }
    }
}

extension AppEnvironment {
    private nonisolated static let downloadsLog = Logger(subsystem: "app.m1k3", category: "model-download")

    // MARK: - The list

    /// The rows Settings shows: the pure catalogue over live facts.
    var downloadItems: [DownloadItem] {
        DownloadCatalogue.items(
            context: .init(
                physicalMemoryGB: Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824,
                afm: downloadsLedger.afm,
                whisperVariantName: selectedWhisperModel.displayName
            ),
            sizes: .manifest(
                sharperEarsBytes: selectedWhisperModel.approxBytes,
                voiceBytes: Int64(VoiceTier.m1k3Voice.approxDownloadMB ?? 192) * 1_000_000
            ),
            facts: Dictionary(uniqueKeysWithValues: DownloadKind.allCases.map { ($0, downloadFacts(for: $0)) })
        )
    }

    /// The statuses without their fractions (`DownloadStatusStore`): what a glass-hosted surface reads. Empty
    /// until `beginObservingDownloadStatuses()` has run, which `OnboardingKit` reads as "still looking".
    var downloadStatuses: [DownloadItem] {
        downloadStatusStore.items
    }

    func beginObservingDownloadStatuses() {
        downloadStatusStore.start { [weak self] in self?.downloadItems ?? [] }
    }

    func endObservingDownloadStatuses() {
        downloadStatusStore.stop()
    }

    /// Everything that can make a brain "in use" (B2), read off live state into the pure policy.
    private var brainUseSnapshot: BrainUseSnapshot {
        var staged: BrainTier?
        if case .staged = brainUpgrade { staged = brainUpgradeTarget }
        return BrainUseSnapshot(
            selectedBrain: selectedBrain,
            servingModelID: currentMLXProvider.modelIdentifier,
            escalatedModelID: deepDiveEscalatedProvider?.modelIdentifier,
            directedTarget: directedBrainTarget,
            stagedSwapTarget: staged,
            removing: removingBrainTiers
        )
    }

    /// Brain tiers whose weights a Remove is deleting right now.
    var removingBrainTiers: Set<BrainTier> {
        Set(downloadsLedger.removing.compactMap(\.brainTier))
    }

    private func downloadFacts(for kind: DownloadKind) -> DownloadFacts {
        let ledger = downloadsLedger
        var facts = DownloadFacts(
            installed: ledger.installed.contains(kind), partial: ledger.partial.contains(kind),
            removing: ledger.removing.contains(kind), scanned: ledger.scanned
        )
        let failure = ledger.failures[kind].map { ModelLoadState.failed(message: $0) } ?? .idle
        facts.load = failure
        switch kind {
        case .lil, .big, .pocket:
            guard let tier = kind.brainTier else { return facts }
            facts.inUse = DownloadUsePolicy.isBrainInUse(tier, brainUseSnapshot)
            if let fraction = ledger.brainFetch[kind] {
                facts.load = .progress(fraction)
            } else if case let .fetching(fraction) = brainUpgrade, brainUpgradeTarget == tier {
                facts.load = .progress(fraction)
            } else if selectedBrain == tier, modelLoad.isActive {
                facts.load = modelLoad
                facts.canCancel = false
            } else if selectedBrain == tier, case .failed = modelLoad {
                facts.load = modelLoad // N5: the failure and a retry, not "In use"
            }
        case .semanticMemory:
            facts.inUse = usingMLXEmbeddings
            facts.installed = facts.installed || usingMLXEmbeddings
            // Turning it on downloads the embedder, then RE-INDEXES the notes (B6): the bar while
            // bytes arrive, "Re-indexing your notes…" for the rest, also when something else started it.
            var downloading: Double?
            if ledger.embedderSwitching, let fraction = ledger.embedderFraction, fraction < 1 { downloading = fraction }
            if let downloading {
                facts.load = .progress(downloading)
            } else {
                facts.reindexing = isReindexing
                // Queued behind a brain / a chat turn: it reads "Downloading" (at nothing yet), not "Download".
                if !isReindexing, ledger.pendingSemanticMemory != nil { facts.load = .progress(0) }
            }
        case .sharperEars:
            facts.inUse = isWhisperKitActive || whisperLoad == .ready
                || UserDefaults.standard.bool(forKey: Self.callTranscriptionEnabledKey)
            facts.load = whisperLoad.isActive ? whisperLoad : whisperFailure(or: failure)
        case .voice:
            facts.inUse = selectedVoiceTier == .m1k3Voice
            facts.load = voiceLoad.isActive ? voiceLoad : voiceFailure(or: failure)
        }
        return facts
    }

    private func whisperFailure(or fallback: ModelLoadState) -> ModelLoadState {
        if case .failed = whisperLoad { return whisperLoad }
        return fallback
    }

    private func voiceFailure(or fallback: ModelLoadState) -> ModelLoadState {
        if case .failed = voiceLoad { return voiceLoad }
        return fallback
    }

    // MARK: - The semantic-memory offer

    /// What the offer's toggle does in the layout beside a download of `tier`: nothing, a reserved invisible
    /// slot (before the first disk scan, so it popping in never shoves the button), or the toggle. The offer is
    /// withheld while a re-index runs, the embedder is switching, or one is already queued (O3).
    func semanticMemoryOfferSlot(alongside tier: BrainTier?) -> SemanticMemoryOffer.Slot {
        let ledger = downloadsLedger
        guard ledger.pendingSemanticMemory == nil, !isReindexing, !ledger.embedderSwitching else { return .none }
        return SemanticMemoryOffer.slot(
            brainTarget: tier, scanned: ledger.scanned, usingMLXEmbeddings: usingMLXEmbeddings,
            installed: ledger.installed.contains(.semanticMemory)
        )
    }

    /// Whether the toggle is on screen beside a download of `tier` (the shown half of the slot).
    func offersSemanticMemory(alongside tier: BrainTier?) -> Bool {
        semanticMemoryOfferSlot(alongside: tier) == .shown
    }

    /// The offer's size, from the same pinned manifest the Settings pane uses ("1.3 GB"); a rough figure, never zero.
    /// Read off the manifest, not `downloadItems`: the toggle can sit inside glass, so it must not observe download ticks.
    var semanticMemorySizeLabel: String {
        let manifest = DownloadSizes.manifest(sharperEarsBytes: 0, voiceBytes: 0)
        return SemanticMemoryOffer.sizeText(catalogueBytes: manifest.bytes[.semanticMemory] ?? 0)
    }

    // MARK: - The semantic-memory queue (O1)

    /// Ask for semantic memory. It does not start here: it waits (pending) until the brain it rides with is
    /// ready, no chat turn is running, no re-index is running and background work is allowed
    /// (`SemanticMemoryQueue`), and `watchSemanticQueue` starts it on the transition that clears the last blocker.
    /// One request per tap: a second one, or one during a re-index, is refused (`false`).
    @discardableResult
    func requestSemanticMemory(after brain: BrainTier? = nil) -> Bool {
        let ledger = downloadsLedger
        guard !usingMLXEmbeddings, SemanticMemoryQueue.canRequest(
            pending: ledger.pendingSemanticMemory != nil, isReindexing: isReindexing,
            embedderSwitching: ledger.embedderSwitching
        ) else { return false }
        ledger.failures[.semanticMemory] = nil
        ledger.pendingSemanticMemory = PendingSemanticMemory(brain: brain)
        if !ledger.scanned { refreshDownloads() } // "is the brain already here" needs the disk facts
        // One hop later: the brain's own start (selectBrain, the fetch) runs right after this call on the
        // same turn, and the queue must see it, not race it.
        Task { @MainActor [weak self] in self?.watchSemanticQueue() }
        return true
    }

    private enum SemanticQueueDecision {
        case wait, start
        case drop(String)
    }

    /// Everything the queue reads, gathered under observation tracking so each transition re-runs it.
    private func semanticQueueDecision(for pending: PendingSemanticMemory) -> SemanticQueueDecision {
        let ledger = downloadsLedger
        _ = ledger.semanticQueueTick // the heat-retry nudge
        var onDisk = true
        var swapPending = false
        var upgradeFetching = false
        if case .fetching = brainUpgrade, pending.brain == nil || brainUpgradeTarget == pending.brain { upgradeFetching = true }
        if let tier = pending.brain, let kind = DownloadKind.allCases.first(where: { $0.brainTier == tier }) {
            onDisk = ledger.installed.contains(kind) || (selectedBrain == tier && modelLoad == .ready)
            if case .staged = brainUpgrade, brainUpgradeTarget == tier { swapPending = true }
            // The brain it rides with did not arrive: say so rather than wait forever.
            if selectedBrain == tier, case .failed = modelLoad {
                return .drop(String(localized: "Didn't start: \(tier.displayName) didn't load. Try again from Settings ▸ Brains & downloads."))
            }
            if case .failed(_, transient: false) = brainUpgrade, brainUpgradeTarget == tier {
                return .drop(String(localized: "Didn't start: \(tier.displayName) didn't download. Try again from Settings ▸ Brains & downloads."))
            }
        } else if case .staged(consented: true) = brainUpgrade {
            swapPending = true
        }
        // ANY brain fetch holds the queue, not only the target's: by design one big download at a
        // time (a Big from Settings and the embedder would split the pipe), so a kit request with
        // no brain of its own waits behind it too.
        let conditions = SemanticMemoryQueue.Conditions(
            brainOnDisk: onDisk, brainFetching: !ledger.brainFetch.isEmpty || upgradeFetching,
            brainLoadInFlight: modelLoad.isActive, brainSwapPending: swapPending,
            isResponding: chat.isResponding, isReindexing: isReindexing, embedderSwitching: ledger.embedderSwitching,
            backgroundWorkAllowed: Self.backgroundWorkAllowed()
        )
        if !conditions.backgroundWorkAllowed { armSemanticHeatRetry() }
        return SemanticMemoryQueue.shouldStartNow(pending: true, conditions) ? .start : .wait
    }

    /// Heat and Low Power Mode are not observable: while they block, nudge the queue every 30 s.
    private func armSemanticHeatRetry() {
        let ledger = downloadsLedger
        guard ledger.semanticRetryTask == nil else { return }
        ledger.semanticRetryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self else { return }
            downloadsLedger.semanticRetryTask = nil
            downloadsLedger.semanticQueueTick += 1
        }
    }

    /// The queue drained (started or dropped): clear the request, DISARM the watch and stop the heat
    /// nudge. The tracking closure only re-arms on a change of what the decision reads, and a drop
    /// changes none of it, so a stuck `semanticWatchArmed` would leave a retry unevaluated until some
    /// unrelated transition (#570 review, both passes). The stale closure still fires harmlessly into
    /// `watchSemanticQueue`'s `pending == nil` guard.
    private func settleSemanticQueue() {
        let ledger = downloadsLedger
        ledger.pendingSemanticMemory = nil
        ledger.semanticWatchArmed = false
        ledger.semanticRetryTask?.cancel()
        ledger.semanticRetryTask = nil
    }

    /// Observe the queue until it drains: re-decide on every change of anything it reads (the brain's load
    /// settling, a turn ending, a re-index ending, a fetch ending, the disk scan landing).
    func watchSemanticQueue() {
        let ledger = downloadsLedger
        guard let pending = ledger.pendingSemanticMemory, !ledger.semanticWatchArmed else { return }
        ledger.semanticWatchArmed = true
        let decision = withObservationTracking {
            semanticQueueDecision(for: pending)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.downloadsLedger.semanticWatchArmed = false
                self?.watchSemanticQueue()
            }
        }
        switch decision {
        case .wait:
            break
        case let .drop(message):
            settleSemanticQueue()
            ledger.failures[.semanticMemory] = message
        case .start:
            settleSemanticQueue()
            Self.downloadsLog.notice("semantic memory queue: starting")
            Task { [weak self] in
                await self?.switchEmbeddings(toMLX: true)
                self?.refreshDownloads()
            }
        }
    }

    // MARK: - Disk facts

    /// Re-read what is on disk off the main actor (the directory walks are slow). Cheap enough
    /// to run on a transition (a load settling, a fetch ending); the newest call wins, so a slow
    /// earlier scan can never overwrite a later one. `onAppear` additionally reads Apple
    /// Intelligence's state (an AFM daemon round-trip) and re-lists the retired brain folders
    /// (a recursive size walk): neither belongs on the per-transition path (B5).
    func refreshDownloads(onAppear: Bool = false) {
        let ledger = downloadsLedger
        ledger.refreshGeneration += 1
        let generation = ledger.refreshGeneration
        let brains = brainInventory
        let embedder = LocalModelInventory.embedder()
        let whisperBase = whisperDownloadBase
        let whisperModel = selectedWhisperModel.modelID
        let voiceStaged = kokoro.isModelStaged
        Task { [weak self] in
            let scan = await Task.detached(priority: .utility) { () -> DiskScan in
                var scan = DiskScan()
                for kind in DownloadKind.allCases {
                    guard let id = kind.brainTier?.mlxModelID else { continue }
                    scan.record(kind, brains.installState(modelID: id))
                }
                if let embedder { scan.record(.semanticMemory, embedder.installState(modelID: DownloadSizes.embedderRepoID)) }
                if WhisperKitProvider.isModelDownloaded(model: whisperModel, downloadBase: whisperBase) {
                    scan.installed.insert(.sharperEars)
                } else if let folder = WhisperKitProvider.modelFolder(model: whisperModel, downloadBase: whisperBase),
                          FileManager.default.fileExists(atPath: folder.path)
                {
                    scan.partial.insert(.sharperEars)
                }
                if voiceStaged { scan.installed.insert(.voice) }
                if onAppear { scan.afm = AppEnvironment.readAFMAvailability() }
                return scan
            }.value
            guard let self, ledger.refreshGeneration == generation else { return }
            ledger.installed = scan.installed
            ledger.partial = scan.partial
            ledger.scanned = true
            if let afm = scan.afm { ledger.afm = afm }
            if onAppear { refreshRetiredWeights() }
        }
    }

    /// What one disk pass found.
    private struct DiskScan {
        var installed: Set<DownloadKind> = []
        var partial: Set<DownloadKind> = []
        var afm: AFMAvailability?

        mutating func record(_ kind: DownloadKind, _ state: LocalModelInventory.InstallState) {
            switch state {
            case .complete: installed.insert(kind)
            case .partial: partial.insert(kind)
            case .absent: break
            }
        }
    }

    /// WhisperKit's download root: the folder beside the knowledge store (as `init` derives it).
    private var whisperDownloadBase: URL? {
        try? Self.storeURL().deletingLastPathComponent()
    }

    // MARK: - Verbs

    /// Start one download. Returns whether it really began (or was queued): a silent guard (a Remove is
    /// deleting it, a foreground load or the upgrade already owns the folder) answers `false`, so a caller that
    /// pins a "Downloading…" row to the answer never pins one no bytes back.
    @discardableResult
    func startDownload(_ kind: DownloadKind) -> Bool {
        let ledger = downloadsLedger
        guard !ledger.removing.contains(kind) else { return false } // busy: a Remove is deleting it
        ledger.failures[kind] = nil
        switch kind {
        case .lil, .big, .pocket:
            // The selected brain whose load failed: "Try again" reloads it (N5).
            if let tier = kind.brainTier, selectedBrain == tier, case .failed = modelLoad {
                selectBrain(tier)
                return true
            }
            return startBrainDownload(kind)
        case .semanticMemory:
            // This is a switch plus a re-index of the notes, not just a download (B6): it queues behind the
            // brain and any chat turn (O1) rather than starting at once, and says so if one is running (O3).
            if isReindexing {
                ledger.failures[kind] = String(localized: "Already re-indexing your notes. Try again when it's done.")
                return false
            }
            return requestSemanticMemory()
        case .sharperEars:
            guard !whisperLoad.isActive else { return false }
            Task { [weak self] in
                await self?.enableWhisperKit()
                self?.refreshDownloads()
            }
            return true
        case .voice:
            return prepareM1K3Voice()
        }
    }

    func cancelDownload(_ kind: DownloadKind) {
        switch kind {
        case .lil, .big, .pocket:
            if downloadsLedger.brainTasks[kind] != nil {
                cancelManagerBrainFetch(kind)
            } else if let tier = kind.brainTier, brainUpgradeTarget == tier, case .fetching = brainUpgrade {
                cancelBrainUpgradeFetch()
                recomputeBrainUpgradeState()
            }
        case .voice:
            // Built-in is the cancel path: it stops the prepare task, resets the bar and keeps
            // the façade on the system voice (the download's completion must not win, #200).
            selectVoiceTier(.builtin)
        case .semanticMemory, .sharperEars:
            break // not cancellable; the catalogue never offers it
        }
        refreshDownloads()
    }

    /// Delete what the row names. Re-checks "in use" against live state, so a stale button
    /// (the state moved while a dialog was open) refuses instead of deleting a serving model.
    /// Every kind goes through `removeOffMain`, which marks the row "removing" synchronously.
    func removeDownload(_ kind: DownloadKind) {
        guard let item = downloadItems.first(where: { $0.kind == kind }), item.actions.contains(.remove) else {
            Self.downloadsLog.notice("remove \(kind.rawValue, privacy: .public): refused, not removable now")
            return
        }
        switch kind {
        case .lil, .big, .pocket:
            guard let modelID = kind.brainTier?.mlxModelID else { return }
            let inventory = brainInventory
            removeOffMain(kind) { try inventory.remove(modelID: modelID) }
        case .semanticMemory:
            let inventory = LocalModelInventory.embedder()
            removeOffMain(kind) { try inventory?.remove(modelID: DownloadSizes.embedderRepoID) }
        case .sharperEars:
            let model = selectedWhisperModel.modelID
            let base = whisperDownloadBase
            // The launch flag flips only once the delete has succeeded (N2): a failed delete
            // leaves WhisperKit enabled for the next launch.
            removeOffMain(kind, onSuccess: { [weak self] in self?.whisperModelRemoved() }) {
                try WhisperKitProvider.removeDownloadedModel(model: model, downloadBase: base)
            }
        case .voice:
            let provider = kokoro
            removeOffMain(kind, prelude: { [weak self] in await self?.selectBuiltinVoiceAndSettle() }) {
                provider.removeStagedModel()
            }
        }
    }

    /// Run `work` off the main actor. The row reads "removing" from this call (synchronously, so
    /// a second tap or a `selectBrain` cannot race the delete) until the work finishes.
    /// `prelude` runs first on the main actor (the voice must stop and settle before its files go);
    /// `onSuccess` only if the delete did not throw.
    private func removeOffMain(
        _ kind: DownloadKind, prelude: (@MainActor () async -> Void)? = nil,
        onSuccess: (@MainActor () -> Void)? = nil, _ work: @escaping @Sendable () throws -> Void
    ) {
        downloadsLedger.removing.insert(kind)
        Task { [weak self] in
            await prelude?()
            let failure: String? = await Task.detached(priority: .utility) {
                do {
                    try work()
                    return nil
                } catch {
                    return DownloadFailureCopy.message(for: error)
                }
            }.value
            guard let self else { return }
            downloadsLedger.removing.remove(kind)
            downloadsLedger.failures[kind] = failure
            if failure == nil { onSuccess?() }
            if kind.brainTier != nil {
                // A removed brain must not stay "staged" for the upgrade machine's auto-swap.
                recomputeBrainUpgradeState()
            }
            Self.downloadsLog.notice("removed \(kind.rawValue, privacy: .public): \(failure ?? "ok", privacy: .public)")
            refreshDownloads()
            refreshRetiredWeights() // after a remove, not on every tick (B5)
        }
    }

    // MARK: - Brain fetches

    private func startBrainDownload(_ kind: DownloadKind) -> Bool {
        guard let tier = kind.brainTier, let modelID = tier.mlxModelID,
              downloadsLedger.brainTasks[kind] == nil else { return false }
        // One writer per folder: a foreground load or the background upgrade owns this brain.
        if selectedBrain == tier, modelLoad.isActive { return false }
        if case .fetching = brainUpgrade, brainUpgradeTarget == tier { return false }
        let ledger = downloadsLedger
        ledger.brainFetch[kind] = 0
        let progress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                guard let self, self.downloadsLedger.brainFetch[kind] != nil else { return }
                self.downloadsLedger.brainFetch[kind] = min(max(fraction, 0), 1)
            }
        }
        Self.downloadsLog.notice("manager fetch start: \(modelID, privacy: .public)")
        ledger.brainTasks[kind] = Task { [weak self] in
            var failure: String?
            do {
                // Retried on transient network errors, including Hub's wrapped ones (#557).
                try await withRetry(
                    onRetry: { attempt, error in
                        Self.downloadsLog.notice(
                            "manager fetch \(modelID, privacy: .public) attempt \(attempt) failed (\(error.localizedDescription, privacy: .public)); retrying"
                        )
                    },
                    operation: { try await BrainWeightsFetcher().fetch(modelID: modelID, progress: progress) }
                )
            } catch is CancellationError {
                return // cancelManagerBrainFetch owns the bookkeeping
            } catch {
                guard !Task.isCancelled else { return }
                failure = DownloadFailureCopy.message(for: error)
            }
            guard !Task.isCancelled, let self else { return }
            // Believe the disk, not the return: the downloader falls back to a local partial
            // when offline instead of throwing.
            if failure == nil, brainInventory.installState(modelID: modelID) != .complete {
                failure = DownloadFailureCopy.message(for: URLError(.notConnectedToInternet))
            }
            ledger.brainFetch[kind] = nil
            ledger.brainTasks[kind] = nil
            ledger.failures[kind] = failure
            Self.downloadsLog.notice("manager fetch end: \(modelID, privacy: .public) \(failure ?? "ok", privacy: .public)")
            if failure == nil { recomputeBrainUpgradeState() }
            refreshDownloads()
        }
        return true
    }

    private func cancelManagerBrainFetch(_ kind: DownloadKind) {
        downloadsLedger.brainTasks[kind]?.cancel()
        downloadsLedger.brainTasks[kind] = nil
        downloadsLedger.brainFetch[kind] = nil
    }

    /// Called where a brain change takes the folder over (`selectBrain`, a directed fetch):
    /// the manager's fetch of that same brain stops first. The partial files stay and resume.
    func cancelManagerBrainFetch(for tier: BrainTier) {
        guard let kind = DownloadKind.allCases.first(where: { $0.brainTier == tier }) else { return }
        cancelManagerBrainFetch(kind)
    }
}
