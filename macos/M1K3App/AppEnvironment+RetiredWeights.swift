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

extension AppEnvironment {
    private nonisolated static let retiredLog = Logger(subsystem: "app.m1k3", category: "brain")

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
        let inventory = LocalModelInventory()
        let keep = retiredWeightsKeepSet
        Task.detached(priority: .utility) {
            let retired = RetiredWeightsPolicy.retired(installed: inventory.installedWeights(), keep: keep)
            await MainActor.run { self.retiredWeights = retired }
        }
    }

    /// Delete one retired folder (the user confirmed), then re-list.
    func removeRetiredWeights(_ weights: InstalledWeights) {
        guard !retiredWeightsKeepSet.contains(weights.repoID) else {
            Self.retiredLog.notice("refused to remove \(weights.repoID, privacy: .public): claimed")
            return
        }
        let inventory = LocalModelInventory()
        Task.detached(priority: .utility) {
            do {
                try inventory.remove(modelID: weights.repoID)
                Self.retiredLog.notice(
                    "removed retired weights \(weights.repoID, privacy: .public) (\(weights.bytes) bytes)"
                )
            } catch {
                Self.retiredLog.error(
                    "remove \(weights.repoID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            await MainActor.run { self.refreshRetiredWeights() }
        }
    }
}
