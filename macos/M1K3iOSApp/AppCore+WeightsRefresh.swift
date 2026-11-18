//
//  AppCore+WeightsRefresh.swift
//  M1K3iOS
//
//  The phone's half of a brain's weights update (WeightsRefresh). Lil keeps loading its previous weights until the
//  person taps Update in Settings ▸ Brain; the new weights download beside them (disk only, no Metal), Switch
//  re-picks the brain onto them (the warm releases the old provider before it builds the new one, so two brains
//  are never resident), and Remove frees the old folder. Each step is a tap: the phone has no "Free up space"
//  list, and an update that misbehaves on an 8 GB phone must leave its fallback on disk until the person decides.
//
//  Every tier-to-folder site asks `loadableModelID(for:)`: the load fetches whatever is missing, so a bare
//  `tier.mlxModelID` would download the update unasked (WeightsRefreshWiringScanTests holds the shell to it).
//
//  Signed: Kev + claude-opus-5.5, 2026-11-18, Confidence 0.7 (glue over WeightsRefresh; the row, the fetch, the
//  switch and the remove are verify-by-launch on the phone). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-11-18 (pre-push review fold) — the row reads disk off the main actor (newest
//  read wins), a brain switch stops the fetch and clears the row, Remove re-checks that the update serves, settled.
//  Review: Kev + claude-opus-5.5, 2026-11-18 (second review fold) — logs under the catalogued mlx-load category
//  (SubsystemGuardTests).

import Foundation
import M1K3Inference
import M1K3MLX
import os

extension AppCore {
    private nonisolated static let refreshLog = Logger(subsystem: "app.m1k3", category: "mlx-load")

    /// The tier's resolution against what is COMPLETE on disk. Nil for Mini.
    nonisolated static func weightsResolution(
        for tier: BrainTier, inventory: LocalModelInventory = LocalModelInventory()
    ) -> WeightsRefresh.Resolution? {
        tier.weightsResolution { inventory.installState(modelID: $0) == .complete }
    }

    /// The repo a tier loads now: current, predecessor until the update is taken, or a first download.
    func loadableModelID(for tier: BrainTier) -> String? {
        Self.weightsResolution(for: tier)?.loadID
    }

    /// What one disk read of a brain's update found.
    private struct UpdateScan {
        var currentComplete = false
        var predecessorComplete = false
        var predecessorOnDisk = false
        var predecessorBytes: Int64 = 0
    }

    /// Re-read the selected brain's update state, off the main actor (a partial folder's size is a recursive walk).
    /// Run on transitions only: Settings appearing, a warm settling, a fetch or a remove ending. The newest read wins.
    func refreshWeightsUpdate() {
        let tier = selectedBrain
        guard let current = tier.mlxModelID, let predecessor = tier.predecessorMLXModelID else {
            weightsUpdate = nil
            leftoverWeights = nil
            return
        }
        weightsUpdateRefreshGeneration += 1
        let generation = weightsUpdateRefreshGeneration
        Task { [weak self] in
            let scan = await Task.detached(priority: .utility) { () -> UpdateScan in
                let inventory = LocalModelInventory()
                let previous = inventory.installState(modelID: predecessor)
                var scan = UpdateScan()
                scan.currentComplete = inventory.installState(modelID: current) == .complete
                scan.predecessorComplete = previous == .complete
                scan.predecessorOnDisk = previous != .absent
                if scan.predecessorOnDisk {
                    scan.predecessorBytes = inventory.installedWeights().first { $0.repoID == predecessor }?.bytes ?? 0
                }
                return scan
            }.value
            guard let self, generation == weightsUpdateRefreshGeneration, selectedBrain == tier else { return }
            // Serving = settled on a repo. A load in flight or a failed one serves nothing: the old weights may be
            // the only copy that works (review catch, 2026-11-18).
            let serving = brainLoad == .ready ? servingMLXModelID : nil
            if weightsUpdateFraction == nil {
                weightsUpdate = WeightsRefresh.update(
                    predecessor: predecessor, currentComplete: scan.currentComplete,
                    predecessorComplete: scan.predecessorComplete, servingID: serving
                )
            }
            leftoverWeights = WeightsRefresh.leftover(
                predecessor: predecessor, current: current, predecessorOnDisk: scan.predecessorOnDisk,
                currentComplete: scan.currentComplete, servingID: serving
            ).map { InstalledWeights(repoID: $0, bytes: scan.predecessorBytes) }
        }
    }

    /// A brain switch: the update row was about the outgoing brain. Stop its fetch (the partial stays and resumes
    /// from the next Update) and clear the row until the new brain's warm settles and re-reads it.
    func resetWeightsUpdateForSwitch() {
        weightsUpdateTask?.cancel()
        weightsUpdateTask = nil
        weightsUpdateFraction = nil
        weightsUpdate = nil
        leftoverWeights = nil
        weightsUpdateRefreshGeneration += 1
    }

    /// "Update": fetch the selected brain's new weights to disk beside the ones serving. Resumes a partial.
    func fetchWeightsUpdate() {
        guard WeightsRefresh.mayFetchUpdate(
            update: weightsUpdate, brainSettled: brainLoad == .ready, fetching: weightsUpdateTask != nil
        ), selectedBrain.predecessorMLXModelID != nil, let modelID = selectedBrain.mlxModelID else { return }
        if let downloadMB = selectedBrain.approxDownloadMB,
           let short = DownloadSpacePreflight.shortfallMB(downloadMB: downloadMB, availableBytes: Self.freeDiskBytes())
        {
            weightsUpdateFailure = DownloadFailureCopy.message(for: DownloadSpacePreflight.InsufficientSpace(
                brain: selectedBrain.displayName, downloadMB: downloadMB, shortfallMB: short
            ))
            return
        }
        weightsUpdateFailure = nil
        weightsUpdateFraction = 0
        Self.refreshLog.notice("weights update: fetching \(modelID, privacy: .public)")
        // Strong-bind at once (a weak capture is mutable, and a nested @Sendable closure reading one trips strict
        // concurrency), the Mac upgrade fetch's pattern.
        let progress: @Sendable (Double) -> Void = { [weak self] fraction in
            guard let self else { return }
            Task { @MainActor in
                guard self.weightsUpdateFraction != nil else { return }
                self.weightsUpdateFraction = min(max(fraction, 0), 1)
            }
        }
        weightsUpdateTask = Task { [weak self] in
            var failure: String?
            do {
                try await BrainWeightsFetcher().fetch(modelID: modelID, progress: progress)
                // Believe the disk, not the return: offline, the downloader returns instead of throwing.
                try LocalModelInventory().requireComplete(modelID: modelID)
            } catch is CancellationError {
                return // a brain switch cancelled it (resetWeightsUpdateForSwitch owns the row)
            } catch {
                failure = DownloadFailureCopy.knownMessage(for: error) ?? error.localizedDescription
            }
            guard let self, !Task.isCancelled else { return }
            weightsUpdateTask = nil
            weightsUpdateFraction = nil
            weightsUpdateFailure = failure
            Self.refreshLog.notice("weights update: fetch ended (\(failure ?? "ok", privacy: .public))")
            refreshWeightsUpdate()
        }
    }

    /// "Switch": re-pick the brain. Its loadable id is now the update, which no longer matches the loaded
    /// predecessor, so the warm releases the old weights and loads the new ones from disk.
    func useWeightsUpdate() {
        guard weightsUpdate == .ready, !chat.isResponding else { return }
        let tier = selectedBrain
        Self.refreshLog.notice("weights update: switching \(tier.rawValue, privacy: .public)")
        weightsUpdate = nil
        selectBrain(tier)
    }

    /// "Remove old weights": delete the predecessor once nothing needs it (re-checked here, not trusted from the row).
    func removeLeftoverWeights() {
        // Re-checked against the live load, not trusted from the row: only once the update serves, settled.
        guard let leftover = leftoverWeights, brainLoad == .ready,
              servingMLXModelID == selectedBrain.mlxModelID else { return }
        let id = leftover.repoID
        leftoverWeights = nil
        Task { [weak self] in
            let failure: String? = await Task.detached(priority: .utility) {
                do {
                    try LocalModelInventory().remove(modelID: id)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            guard let self else { return }
            weightsUpdateFailure = failure
            Self.refreshLog.notice("weights update: removed \(id, privacy: .public) (\(failure ?? "ok", privacy: .public))")
            refreshWeightsUpdate()
        }
    }
}
