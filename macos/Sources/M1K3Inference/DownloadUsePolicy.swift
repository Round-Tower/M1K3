//
//  DownloadUsePolicy.swift
//  M1K3Inference
//
//  "Is this brain in use?" for Settings > Brains & downloads, as one pure decision so Remove
//  can never delete weights something is about to read. In use means ANY of: the label says
//  so (`selectedBrain`), the MLX slot is serving it (`currentMLXProvider`), a deep dive has
//  escalated into it (the slot points at Big while the label stays Lil), the user directed a
//  switch to it that has not completed, a consented auto-swap is staged for it, or a Remove of
//  it is already running.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.85 (pure; the app feeds it live
//  facts in AppEnvironment+Downloads). Prior: none (new file).

import Foundation

public struct BrainUseSnapshot: Equatable, Sendable {
    public var selectedBrain: BrainTier
    /// `currentMLXProvider.modelIdentifier`.
    public var servingModelID: String?
    /// The deep-dive escalation's provider model id, while one is live.
    public var escalatedModelID: String?
    /// `directedBrainTarget`: the user's pick, not yet swapped in.
    public var directedTarget: BrainTier?
    /// The target of a `.staged` auto-swap, nil in any other upgrade state.
    public var stagedSwapTarget: BrainTier?
    /// Tiers a Remove is currently deleting.
    public var removing: Set<BrainTier>

    public init(
        selectedBrain: BrainTier, servingModelID: String? = nil, escalatedModelID: String? = nil,
        directedTarget: BrainTier? = nil, stagedSwapTarget: BrainTier? = nil, removing: Set<BrainTier> = []
    ) {
        self.selectedBrain = selectedBrain
        self.servingModelID = servingModelID
        self.escalatedModelID = escalatedModelID
        self.directedTarget = directedTarget
        self.stagedSwapTarget = stagedSwapTarget
        self.removing = removing
    }
}

public enum DownloadUsePolicy {
    public static func isBrainInUse(_ tier: BrainTier, _ snapshot: BrainUseSnapshot) -> Bool {
        if snapshot.selectedBrain == tier { return true }
        if let id = tier.mlxModelID, id == snapshot.servingModelID || id == snapshot.escalatedModelID { return true }
        if snapshot.directedTarget == tier || snapshot.stagedSwapTarget == tier { return true }
        return snapshot.removing.contains(tier)
    }

    /// `selectBrain` refuses a tier whose weights a Remove is deleting.
    public static func mayLoad(_ tier: BrainTier, removing: Set<BrainTier>) -> Bool {
        !removing.contains(tier)
    }
}
