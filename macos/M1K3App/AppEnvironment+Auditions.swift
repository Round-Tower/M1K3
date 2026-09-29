//
//  AppEnvironment+Auditions.swift
//  M1K3App
//
//  Model auditions, app side: build a tier's MLX brain from its audition when
//  one is chosen (Settings > Advanced, or `-audition.lil org/repo` at launch),
//  import a checkpoint folder the user picked, and swap the live brain when
//  the choice changes. The store and the folder load live in M1K3MLX
//  (AuditionStore, MLXBrainProvider(modelDirectory:)); this is the glue.
//
//  An audition is unpinned by nature: nothing checks its bytes against a
//  manifest, and the pinned store is never touched. The pane says so.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-29, Confidence 0.75 (the store and
//  the no-op predicate are unit-pinned; this glue is verify-by-launch).
//  Prior: Unknown
//

import Foundation
import M1K3Inference
import M1K3MLX
import os

extension AppEnvironment {
    nonisolated static let auditionStore = AuditionStore.standard()
    private nonisolated static let auditionLog = Logger(subsystem: "app.m1k3", category: "model-download")

    /// The MLX brain for `tier`: its audition when one is chosen AND on disk, else
    /// `stockModelID`. Every place that builds a tier's brain goes through here, so
    /// an audition reaches chat, voice, MCP asks and the deep dive alike.
    /// `live`: this brain is about to be LOADED as the app's brain (a launch with an MLX
    /// tier selected, a switch), so a load that never finishes is remembered for the next
    /// launch (`AuditionSelection.recordsPendingLoad`). The launch slot built for Mini and
    /// the deep dive's Big pass false.
    nonisolated static func makeMLXBrain(
        for tier: BrainTier, stockModelID: String, maxTokens: Int, live: Bool = true
    ) -> MLXBrainProvider {
        if let directory = AuditionSelection.directory(forTier: tier.rawValue, store: auditionStore) {
            auditionLog.notice(
                "audition serving \(tier.rawValue, privacy: .public): \(directory.path, privacy: .public)"
            )
            if live { AuditionSelection.recordPendingLoad(tier: tier.rawValue) }
            return MLXBrainProvider(modelDirectory: directory, maxTokens: maxTokens)
        }
        return MLXBrainProvider(modelID: stockModelID, maxTokens: maxTokens)
    }

    /// The eval stage's MLX brain: an override naming an imported audition loads from
    /// its folder, so `run_chateval.py --model lil=<org/repo>` A/Bs anything imported.
    /// An imported audition WINS over the hub id of the same name, and says so in the log,
    /// so an A/B never quietly compares a local copy against itself.
    nonisolated static func evalMLXBrain(modelID: String, maxTokens: Int) -> MLXBrainProvider {
        if let folder = auditionStore?.directory(for: modelID) {
            auditionLog.notice("eval \(modelID, privacy: .public) loads the imported audition folder, not the hub")
            return MLXBrainProvider(modelDirectory: folder, maxTokens: maxTokens)
        }
        return MLXBrainProvider(modelID: modelID, maxTokens: maxTokens)
    }

    /// At launch, before the first brain is built: an audition whose last load never
    /// reached ready is dropped, so a checkpoint that kills the app can't do it twice.
    @discardableResult
    nonisolated static func dropAuditionThatNeverLoaded() -> String? {
        guard let tier = AuditionSelection.dropUnfinishedLoad() else { return nil }
        auditionLog.error("audition for \(tier, privacy: .public) never finished loading last launch — back to stock")
        return tier
    }

    /// The live brain reached ready: clear the sentinel only when it was loaded from an
    /// audition folder (review on #452: any ready used to clear any pending load).
    func auditionLoadFinished(sourceKey: String) {
        if sourceKey.hasPrefix("dir:") { AuditionSelection.clearPendingLoad() }
    }

    /// What `tier` should be serving right now, as a provider `sourceKey`: its
    /// audition's folder when one stands in, else nil (the stock hub id).
    nonisolated static func auditionSourceKey(for tier: BrainTier) -> String? {
        AuditionSelection.directory(forTier: tier.rawValue, store: auditionStore).map(AuditionStore.sourceKey(for:))
    }

    enum AuditionChange: Equatable {
        case applied
        /// Saved; the tier isn't the live brain, so it applies at the next switch.
        case savedForLater
        /// Refused: a deep dive holds the MLX slot.
        case busy
    }

    /// Choose (or clear, with nil) the audition for `tier`. The live brain reloads now;
    /// another tier's choice waits for the next switch. Refused while a deep dive runs,
    /// because the dive owns the slot and would restore the old brain afterwards.
    @discardableResult
    func setAudition(_ repoID: String?, for tier: BrainTier) -> AuditionChange {
        guard deepDelegationTaskLabel == nil else { return .busy }
        let key = AuditionSelection.key(forTier: tier.rawValue)
        if let repoID {
            UserDefaults.standard.set(repoID, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        Self.auditionLog.notice("audition for \(tier.rawValue, privacy: .public) → \(repoID ?? "stock", privacy: .public)")
        guard selectedBrain == tier, tier.mlxModelID != nil else { return .savedForLater }
        AuditionSelection.clearPendingLoad() // the pending load, if any, is being replaced
        _ = selectBrain(tier)
        return .applied
    }

    /// Copy the checkpoint at `folder` into the audition store, off the main actor
    /// (a multi-GB copy can take a while off-volume). The open panel's grant covers
    /// the folder for this process; the scoped call is belt and braces.
    /// `name`: the `org/model` it will be known by (the panel prefills the guess from
    /// the folder). The name drives name-keyed tuning, so a plain folder called
    /// `lfm25-2.6b` is best imported as its real hub name.
    nonisolated static func importAudition(from folder: URL, as name: String) async throws -> AuditionModel {
        guard let store = auditionStore else { throw CocoaError(.fileNoSuchFile) }
        let repoID = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await Task.detached(priority: .userInitiated) {
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            return try store.importFolder(folder, repoID: repoID)
        }.value
    }

    /// Delete an audition. Tiers using it go back to stock FIRST (the live brain
    /// swaps before its folder disappears). Refused during a deep dive, which may
    /// have parked a brain loaded from it.
    func removeAudition(_ repoID: String) throws -> AuditionChange {
        guard deepDelegationTaskLabel == nil else { return .busy }
        for tier in BrainTier.allCases where AuditionSelection.repoID(forTier: tier.rawValue) == repoID {
            setAudition(nil, for: tier)
        }
        try Self.auditionStore?.remove(repoID: repoID)
        return .applied
    }
}
