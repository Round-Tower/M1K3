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

    /// The ids nothing may offer for removal: pinned, shipped, or loaded now.
    var retiredWeightsKeepSet: Set<String> {
        var keep = Set(PinnedWeights.all.keys)
        for tier in BrainTier.allCases {
            if let id = tier.mlxModelID { keep.insert(id) }
        }
        keep.insert(currentMLXProvider.modelIdentifier)
        return keep
    }

    /// Re-list retired folders off the main actor (directory walks over GBs of
    /// weights); publishes into `retiredWeights` for the Settings row.
    func refreshRetiredWeights() {
        let inventory = brainInventory
        let keep = retiredWeightsKeepSet
        // House idiom: the outer Task stays on the main actor; only the pure,
        // Sendable disk walk is sent away. `self` never crosses isolation.
        Task { [weak self] in
            let retired = await Task.detached(priority: .utility) {
                RetiredWeightsPolicy.retired(installed: inventory.installedWeights(), keep: keep)
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
        guard !retiredWeightsKeepSet.contains(weights.repoID) else {
            Self.retiredLog.notice("refused to remove \(weights.repoID, privacy: .public): claimed")
            return
        }
        let inventory = brainInventory
        retiredWeightsFailure = nil
        Task { [weak self] in
            let failure: RetiredWeightsFailure? = await Task.detached(priority: .utility) {
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
