//
//  AppEnvironment+RetiredWeights.swift
//  M1K3App
//
//  Settings ▸ Brain's "Free up space" row: the brain folders on disk that nothing
//  claims any more (a previous pin, an eval override, a spike). Listing is the
//  pure RetiredWeightsPolicy over LocalModelInventory; the delete is one user
//  tap behind a confirmation, never automatic. The keep-set is assembled HERE
//  from the three sources of truth — PinnedWeights, every shipped tier's id,
//  and the model loaded right now — so a folder mid-use is never offered.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-05, Confidence 0.8 (glue over a
//  tested policy; the row, the dialog and the delete are verify-by-launch).
//  Prior: none. Issue #222.
//  Review: Kev + claude-opus-5.5, 2026-11-18 — the keep-set reads each tier's claimed ids (WeightsRefresh): a
//  predecessor is kept while it is what loads, then lists here though its pin stays.
//  Review: Kev + claude-opus-5.5, 2026-11-18 (pre-push review fold) — the keep-set is built off the main actor and
//  keeps a predecessor until its update has served; the delete re-checks it there.

import Foundation
import M1K3Inference
import M1K3MLX
import os

/// A removal that did not free its space — the reason travels with the folder
/// it was about, so a stale banner can never sit above a different folder.
struct RetiredWeightsFailure: Equatable {
    let repoID: String
    let message: String
}

extension AppEnvironment {
    private nonisolated static let retiredLog = Logger(subsystem: "app.m1k3", category: "mlx-load")

    /// The ids nothing may offer for removal: pinned, claimed by a tier, or loaded now. A tier claims its
    /// predecessor only while that is what it loads (WeightsRefresh), and keeps it until the update has SERVED: after
    /// a Switch whose load failed, the old weights are the only copy that works (review catch, 2026-11-18). The pin
    /// stays (it verifies the old weights while they serve). Disk reads: run it off the main actor.
    nonisolated static func retiredWeightsKeepSet(
        inventory: LocalModelInventory, loadedModelID: String, settledOn: (tier: BrainTier, modelID: String)?
    ) -> Set<String> {
        let predecessors = Set(BrainTier.allCases.compactMap(\.predecessorMLXModelID))
        var keep = Set(PinnedWeights.all.keys).subtracting(predecessors)
        for tier in BrainTier.allCases {
            keep.formUnion(weightsResolution(for: tier, inventory: inventory)?.claimedIDs ?? [])
            guard let predecessor = tier.predecessorMLXModelID, let current = tier.lineageMLXModelIDs.first else { continue }
            let served = settledOn?.tier == tier ? settledOn?.modelID : nil
            let leftover = WeightsRefresh.leftover(
                predecessor: predecessor, current: current, predecessorOnDisk: true,
                currentComplete: inventory.installState(modelID: current) == .complete, servingID: served
            )
            if leftover == nil { keep.insert(predecessor) }
        }
        keep.insert(loadedModelID)
        return keep
    }

    /// The live inputs the keep-set reads, gathered on the main actor.
    private var retiredWeightsKeepInputs: (loaded: String, settledOn: (tier: BrainTier, modelID: String)?) {
        let loaded = currentMLXProvider.modelIdentifier
        return (loaded, modelLoad == .ready ? (selectedBrain, loaded) : nil)
    }

    /// Re-list retired folders off the main actor (directory walks over GBs of
    /// weights); publishes into `retiredWeights` for the Settings row.
    func refreshRetiredWeights() {
        let inventory = brainInventory
        let inputs = retiredWeightsKeepInputs
        // House idiom: the outer Task stays on the main actor; only the pure,
        // Sendable disk walk is sent away. `self` never crosses isolation.
        Task { [weak self] in
            let retired = await Task.detached(priority: .utility) {
                let keep = Self.retiredWeightsKeepSet(
                    inventory: inventory, loadedModelID: inputs.loaded, settledOn: inputs.settledOn
                )
                return RetiredWeightsPolicy.retired(installed: inventory.installedWeights(), keep: keep)
            }.value
            self?.retiredWeights = retired
            // The folder the banner was about is gone (removed, or claimed again):
            // the banner goes with it. A failure for a folder still listed stays.
            if let failed = self?.retiredWeightsFailure, !retired.contains(where: { $0.repoID == failed.repoID }) {
                self?.retiredWeightsFailure = nil
            }
        }
    }

    /// Delete one retired folder (the user confirmed), then re-list.
    func removeRetiredWeights(_ weights: InstalledWeights) {
        let inventory = brainInventory
        let inputs = retiredWeightsKeepInputs
        retiredWeightsFailure = nil
        Task { [weak self] in
            let failure: RetiredWeightsFailure? = await Task.detached(priority: .utility) {
                // Re-checked at the delete, off the main actor: the state may have moved since the row was listed.
                let keep = Self.retiredWeightsKeepSet(
                    inventory: inventory, loadedModelID: inputs.loaded, settledOn: inputs.settledOn
                )
                guard !keep.contains(weights.repoID) else {
                    Self.retiredLog.notice("refused to remove \(weights.repoID, privacy: .public): claimed")
                    return nil
                }
                do {
                    try inventory.remove(modelID: weights.repoID)
                    Self.retiredLog.notice(
                        "removed retired weights \(weights.repoID, privacy: .public) (\(weights.bytes) bytes)"
                    )
                    return nil
                } catch {
                    Self.retiredLog.error(
                        "remove \(weights.repoID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                    )
                    // The dialog promised freed space; a silent failure would break that
                    // promise. The row shows the reason until the next successful removal.
                    return RetiredWeightsFailure(
                        repoID: weights.repoID,
                        message: "Couldn't remove \(weights.repoID): \(error.localizedDescription)"
                    )
                }
            }.value
            self?.retiredWeightsFailure = failure
            self?.refreshRetiredWeights()
        }
    }
}
