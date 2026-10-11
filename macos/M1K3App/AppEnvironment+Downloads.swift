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

    func startDownload(_ kind: DownloadKind) {
        let ledger = downloadsLedger
        guard !ledger.removing.contains(kind) else { return } // busy: a Remove is deleting it
        ledger.failures[kind] = nil
        switch kind {
        case .lil, .big, .pocket:
            // The selected brain whose load failed: "Try again" reloads it (N5).
            if let tier = kind.brainTier, selectedBrain == tier, case .failed = modelLoad {
                selectBrain(tier)
                return
            }
            startBrainDownload(kind)
        case .semanticMemory:
            // This is a switch plus a re-index of the notes, not just a download (B6): say so
            // rather than silently doing nothing.
            if isReindexing {
                ledger.failures[kind] = String(localized: "Already re-indexing your notes. Try again when it's done.")
                return
            }
            if chat.isResponding {
                ledger.failures[kind] = String(localized: "I'm answering right now. Try again when I'm done.")
                return
            }
            Task { [weak self] in
                await self?.switchEmbeddings(toMLX: true)
                self?.refreshDownloads()
            }
        case .sharperEars:
            Task { [weak self] in
                await self?.enableWhisperKit()
                self?.refreshDownloads()
            }
        case .voice:
            prepareM1K3Voice()
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

    private func startBrainDownload(_ kind: DownloadKind) {
        guard let tier = kind.brainTier, let modelID = tier.mlxModelID,
              downloadsLedger.brainTasks[kind] == nil else { return }
        // One writer per folder: a foreground load or the background upgrade owns this brain.
        if selectedBrain == tier, modelLoad.isActive { return }
        if case .fetching = brainUpgrade, brainUpgradeTarget == tier { return }
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
