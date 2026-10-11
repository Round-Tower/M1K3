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

import Foundation
import M1K3Inference
import M1K3MLX
import M1K3Voice
import M1K3WhisperKit
import os

/// What the manager remembers between renders. Observable so the pane repaints on progress.
@MainActor @Observable
final class DownloadsLedger {
    /// Items found on disk by the last `refreshDownloads()`.
    var installed: Set<DownloadKind> = []
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

    private func downloadFacts(for kind: DownloadKind) -> DownloadFacts {
        let ledger = downloadsLedger
        let onDisk = ledger.installed.contains(kind)
        let failure = ledger.failures[kind].map { ModelLoadState.failed(message: $0) } ?? .idle
        switch kind {
        case .lil, .big, .pocket:
            guard let tier = kind.brainTier else { return DownloadFacts() }
            let serving = selectedBrain == tier || tier.mlxModelID == currentMLXProvider.modelIdentifier
            let facts = DownloadFacts(installed: onDisk, load: failure, inUse: serving)
            if let fraction = ledger.brainFetch[kind] {
                return DownloadFacts(installed: onDisk, load: .progress(fraction), inUse: serving)
            }
            if case let .fetching(fraction) = brainUpgrade, brainUpgradeTarget == tier {
                return DownloadFacts(installed: onDisk, load: .progress(fraction), inUse: serving)
            }
            if selectedBrain == tier, modelLoad.isActive {
                return DownloadFacts(installed: onDisk, load: modelLoad, inUse: serving, canCancel: false)
            }
            return facts
        case .semanticMemory:
            if ledger.embedderSwitching {
                let load: ModelLoadState = ledger.embedderFraction.map { $0 < 1 ? .progress($0) : .preparing } ?? .preparing
                return DownloadFacts(installed: onDisk, load: load, inUse: usingMLXEmbeddings)
            }
            return DownloadFacts(installed: onDisk || usingMLXEmbeddings, load: failure, inUse: usingMLXEmbeddings)
        case .sharperEars:
            let serving = isWhisperKitActive || whisperLoad == .ready
                || UserDefaults.standard.bool(forKey: Self.callTranscriptionEnabledKey)
            return DownloadFacts(installed: onDisk, load: whisperLoad.isActive ? whisperLoad : whisperFailure(or: failure), inUse: serving)
        case .voice:
            let serving = selectedVoiceTier == .m1k3Voice
            return DownloadFacts(installed: onDisk, load: voiceLoad.isActive ? voiceLoad : voiceFailure(or: failure), inUse: serving)
        }
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

    /// Re-read what is on disk (and Apple Intelligence's state) off the main actor: the
    /// directory walks and the AFM probe are slow. Also re-lists the retired brain folders,
    /// so "Free up space" stays one list with the rows above it.
    func refreshDownloads() {
        let brains = brainInventory
        let embedder = LocalModelInventory.embedder()
        let whisperBase = whisperDownloadBase
        let whisperModel = selectedWhisperModel.modelID
        let voiceStaged = kokoro.isModelStaged
        Task { [weak self] in
            let (installed, afm) = await Task.detached(priority: .utility) { () -> (Set<DownloadKind>, AFMAvailability) in
                var found: Set<DownloadKind> = []
                for kind in DownloadKind.allCases {
                    if let id = kind.brainTier?.mlxModelID, brains.isInstalled(modelID: id) { found.insert(kind) }
                }
                if embedder?.isInstalled(modelID: DownloadSizes.embedderRepoID) == true { found.insert(.semanticMemory) }
                if WhisperKitProvider.isModelDownloaded(model: whisperModel, downloadBase: whisperBase) {
                    found.insert(.sharperEars)
                }
                if voiceStaged { found.insert(.voice) }
                return (found, AppEnvironment.readAFMAvailability())
            }.value
            guard let self else { return }
            downloadsLedger.installed = installed
            downloadsLedger.afm = afm
            refreshRetiredWeights()
        }
    }

    /// WhisperKit's download root: the folder beside the knowledge store (as `init` derives it).
    private var whisperDownloadBase: URL? {
        try? Self.storeURL().deletingLastPathComponent()
    }

    // MARK: - Verbs

    func startDownload(_ kind: DownloadKind) {
        downloadsLedger.failures[kind] = nil
        switch kind {
        case .lil, .big, .pocket:
            startBrainDownload(kind)
        case .semanticMemory:
            guard !isReindexing else { return }
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
            // Stop the launch path from trying to bring it back; the user chose to remove it.
            UserDefaults.standard.set(false, forKey: Self.whisperEnabledKey)
            removeOffMain(kind) { try WhisperKitProvider.removeDownloadedModel(model: model, downloadBase: base) }
        case .voice:
            selectVoiceTier(.builtin) // also cancels a prepare in flight and resets the bar
            let provider = kokoro
            Task { [weak self] in
                provider.removeStagedModel()
                self?.refreshDownloads()
            }
        }
    }

    private func removeOffMain(_ kind: DownloadKind, _ work: @escaping @Sendable () throws -> Void) {
        Task { [weak self] in
            let failure: String? = await Task.detached(priority: .utility) {
                do {
                    try work()
                    return nil
                } catch {
                    return DownloadFailureCopy.message(for: error)
                }
            }.value
            guard let self else { return }
            downloadsLedger.failures[kind] = failure
            if kind.brainTier != nil {
                // A removed brain must not stay "staged" for the upgrade machine's auto-swap.
                recomputeBrainUpgradeState()
            }
            Self.downloadsLog.notice("removed \(kind.rawValue, privacy: .public): \(failure ?? "ok", privacy: .public)")
            refreshDownloads()
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
            if failure == nil, !brainInventory.isInstalled(modelID: modelID) {
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
