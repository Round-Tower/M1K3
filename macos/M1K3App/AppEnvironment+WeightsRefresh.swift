//
//  AppEnvironment+WeightsRefresh.swift
//  M1K3App
//
//  The Mac's half of a brain's weights update (WeightsRefresh). Every place that turns a tier into a folder asks
//  `loadableModelID(for:)`: the provider loads through a downloader that fetches whatever is missing, so a stray
//  `tier.mlxModelID` would be a silent 3 GB fetch behind the person's back (WeightsRefreshWiringScanTests holds the shell to
//  it). The update itself rides Settings ▸ Brains & downloads: "Update" fetches the new weights with the manager's
//  own brain fetch, "Switch" re-picks the brain, and the old folder then lists under "Free up space".
//
//  Signed: Kev + claude-opus-5.5, 2026-11-18, Confidence 0.75 (glue over WeightsRefresh and the downloads
//  manager; the rows, the fetch and the switch are verify-by-launch). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-11-18 (pre-push review fold) — Switch refuses under a turn or a dive (the
//  pane disables it too).

import Foundation
import M1K3Inference
import M1K3MLX
import os

extension AppEnvironment {
    private nonisolated static let refreshLog = Logger(subsystem: "app.m1k3", category: "mlx-load")

    /// The tier's resolution against what is COMPLETE on disk (never "a safetensors exists": a torn update must
    /// not win over the working weights). Nil for Mini.
    nonisolated static func weightsResolution(
        for tier: BrainTier, inventory: LocalModelInventory
    ) -> WeightsRefresh.Resolution? {
        tier.weightsResolution { inventory.installState(modelID: $0) == .complete }
    }

    func weightsResolution(for tier: BrainTier) -> WeightsRefresh.Resolution? {
        Self.weightsResolution(for: tier, inventory: brainInventory)
    }

    /// The repo a tier loads now: its current weights, its predecessor until the update is taken, or the current
    /// weights as a first download. Nil for Mini.
    func loadableModelID(for tier: BrainTier) -> String? {
        weightsResolution(for: tier)?.loadID
    }

    /// The update a brain's row offers, from the downloads ledger's scan (no disk read on the render path):
    /// `.available` while only the predecessor is complete, `.ready` once the update is complete but the
    /// predecessor is still the one loaded.
    func weightsUpdate(for tier: BrainTier, currentComplete: Bool, predecessorComplete: Bool) -> WeightsUpdate? {
        WeightsRefresh.update(
            predecessor: tier.predecessorMLXModelID, currentComplete: currentComplete,
            predecessorComplete: predecessorComplete,
            servingID: selectedBrain == tier ? currentMLXProvider.modelIdentifier : nil
        )
    }

    /// "Switch": re-pick the brain. Its resolution is now the update, which no longer matches the loaded
    /// predecessor, so `selectBrain` builds the new weights (from disk) instead of the already-loaded no-op.
    func useWeightsUpdate(_ tier: BrainTier) {
        // Never under a turn or a dive: selectBrain retires the loaded brain, and refuses (silently) mid-dive.
        guard tier == selectedBrain, !chat.isResponding, deepDelegationTaskLabel == nil else { return }
        Self.refreshLog.notice("weights update: switching \(tier.rawValue, privacy: .public) to its new weights")
        selectBrain(tier)
        refreshDownloads()
        refreshRetiredWeights()
    }
}
