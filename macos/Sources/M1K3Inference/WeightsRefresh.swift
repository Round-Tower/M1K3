//
//  WeightsRefresh.swift
//  M1K3Inference
//
//  The update path for a brain whose weights change under it. Before this, a new id in `BrainTier.backing` read as
//  "not downloaded": every existing user hit the launch gate's 3 GB download and the old folder was stranded (Lil
//  did it three times: DWQ-2510, the 2507, Qwen3.5-4B). Now a tier remembers ONE predecessor. When only the
//  predecessor is complete on disk it loads as it always did, and the update is an offer the person takes with a
//  tap ("downloads only when you ask"). The switch is their second tap; the old folder then drops out of the claim
//  and lists under Settings' "Free up space". No idle swap and no automatic delete: a challenger pass (2026-11-18)
//  named the phone's two-brains-in-memory risk and an unverified new pack as reasons to keep both by hand.
//
//  Every place that turns a tier into a folder MUST go through `loadID`: `MLXBrainProvider` loads through a
//  downloader that fetches whatever is missing, so a stray `tier.mlxModelID` is a silent 3 GB fetch. A source-scan
//  test, WeightsRefreshWiringScanTests, holds the shells to it.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-18, Confidence 0.8 (pure, pinned by WeightsRefreshTests; the Settings
//  rows, the fetch and the switch are verify-by-launch). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-11-18 (pre-push review fold) — the old weights are left over only once the
//  update has SERVED (a failed Switch leaves them the only working copy); mayFetchUpdate guards Update on a settled
//  brain and a fresh row.

import Foundation

public enum WeightsRefresh {
    /// Which folder a tier loads, given what is complete on disk.
    public enum Resolution: Equatable, Sendable {
        /// The current weights are complete: load them.
        case current(String)
        /// Only the predecessor is complete: load it, and offer `update`.
        case predecessor(String, update: String)
        /// Nothing complete: the current weights are a first download (the gate, as before).
        case download(String)

        /// The repo to build the provider from.
        public var loadID: String {
            switch self {
            case let .current(id), let .predecessor(id, _), let .download(id): id
            }
        }

        /// The update on offer, if any. A first download is not an update.
        public var updateTarget: String? {
            if case let .predecessor(_, update) = self { return update }
            return nil
        }

        /// True when the load needs no download.
        public var isOnDisk: Bool {
            if case .download = self { return false }
            return true
        }

        /// The folders this tier still claims (never offered for removal). The update's id is claimed always,
        /// so a half-fetched update is kept to resume; the predecessor only while it is what loads.
        public var claimedIDs: [String] {
            switch self {
            case let .current(id), let .download(id): [id]
            case let .predecessor(old, update): [update, old]
            }
        }
    }

    /// Resolve a tier's folder. `isComplete` must mean "every file the load needs is on disk" (the inventory's
    /// `.complete`), never "a safetensors exists": a torn update would load, fail its heal and re-download unasked.
    public static func resolve(current: String, predecessor: String?, isComplete: (String) -> Bool) -> Resolution {
        if isComplete(current) { return .current(current) }
        if let predecessor, isComplete(predecessor) { return .predecessor(predecessor, update: current) }
        return .download(current)
    }

    /// The update a brain's row offers: `.available` while only the predecessor is complete, `.ready` once the
    /// update is complete and the predecessor still serves (`servingID`: the repo loaded now, nil when none).
    public static func update(
        predecessor: String?, currentComplete: Bool, predecessorComplete: Bool, servingID: String?
    ) -> WeightsUpdate? {
        guard let predecessor else { return nil }
        if !currentComplete { return predecessorComplete ? .available : nil }
        return servingID == predecessor ? .ready : nil
    }

    /// The predecessor, once nothing needs it: the update is complete AND has served (`servingID` is the update,
    /// settled). Not merely "not serving": after a Switch whose load failed, nothing serves and the old weights are
    /// the only copy that works (review catch, 2026-11-18). The person removes it with a tap (the phone's
    /// Settings ▸ Brain; the Mac lists it under "Free up space").
    public static func leftover(
        predecessor: String?, current: String, predecessorOnDisk: Bool, currentComplete: Bool, servingID: String?
    ) -> String? {
        guard let predecessor, predecessorOnDisk, currentComplete, servingID == current else { return nil }
        return predecessor
    }

    /// Whether Update may start a fetch: the row is `.available` (re-read, not a stale row from another brain), the
    /// brain is settled (a warm in flight may be downloading the same folder), and no update fetch is running.
    public static func mayFetchUpdate(update: WeightsUpdate?, brainSettled: Bool, fetching: Bool) -> Bool {
        update == .available && brainSettled && !fetching
    }
}

public extension BrainTier {
    /// The repo this tier shipped before its current one, kept loadable until the person takes the update. ONE at
    /// most: each is kept in step with the exact-id rules (`usesVLMLoadPath`, `ThinkBudget`), the pins and the
    /// energy rates. Set it in the same commit that changes `backing`; drop it a release or two later.
    var predecessorMLXModelID: String? {
        switch self {
        case .mini, .pocket, .lil, .big: nil
        }
    }

    /// The current repo, then the predecessor: every id that may load as this tier. Empty for Mini.
    var lineageMLXModelIDs: [String] {
        guard let current = mlxModelID else { return [] }
        return [current] + (predecessorMLXModelID.map { [$0] } ?? [])
    }

    /// Whether `modelID` is one of this tier's repos (case-blind, exact otherwise: never a family match).
    func lineageContains(_ modelID: String) -> Bool {
        let wanted = modelID.lowercased()
        return lineageMLXModelIDs.contains { $0.lowercased() == wanted }
    }

    /// The tier whose lineage holds `modelID`, if any.
    init?(lineageModelID modelID: String) {
        guard let tier = BrainTier.allCases.first(where: { $0.lineageContains(modelID) }) else { return nil }
        self = tier
    }

    /// This tier's resolution against what is complete on disk.
    func weightsResolution(isComplete: (String) -> Bool) -> WeightsRefresh.Resolution? {
        guard let current = mlxModelID else { return nil }
        return WeightsRefresh.resolve(current: current, predecessor: predecessorMLXModelID, isComplete: isComplete)
    }
}
