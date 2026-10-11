//
//  AppEnvironment+Auditions.swift
//  M1K3App
//
//  Model auditions, app side: build a tier's MLX brain from its audition when
//  one is chosen (`-audition.lil org/repo` at launch, a developer / eval path; Settings
//  stopped offering auditions in 1.1). The store and the folder load live in M1K3MLX
//  (AuditionStore, MLXBrainProvider(modelDirectory:)); this is the glue.
//
//  An audition is unpinned by nature: nothing checks its bytes against a
//  manifest, and the pinned store is never touched.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-29, Confidence 0.75 (the store and
//  the no-op predicate are unit-pinned; this glue is verify-by-launch).
//  Prior: Unknown
//
//  Review: Kev + claude-fable-5.1, 2026-09-29 — #452 review fold (both passes on 95586c16):
//  the sentinel also clears on a failed load and a normal quit (a quit mid-load cost the
//  audition), remove deletes off the main actor, `isServingAudition` lets the pane refuse
//  an import under the live brain, and a launch-argument audition refuses both a new pick
//  and a remove (`.setAtLaunch`). A stale settle can't clear a newer load's sentinel: a
//  switch cancels the preload, which returns before setting `.ready`. Trade-off: a quit
//  also clears it, so a checkpoint that HANGS (not crashes) is retried each launch.
//  A load that FAILS cleanly keeps the choice on purpose: the failure is on screen with
//  its message and Stock is one pick away; only a load that never settles is dropped.
//  Carried: moving the tier/busy decisions into a package as pure functions.
//  Confidence 0.75, still verify-by-launch.
//  Review: Kev + claude-opus-5.5, 2026-10-11 — 1.1 Settings restructure: setAudition / importAudition /
//  removeAudition / isServingAudition / AuditionChange left with the Advanced pane's audition UI;
//  makeMLXBrain and evalMLXBrain stay (evals and `-audition.*` use them). `retireAuditions` replaces
//  dropAuditionThatNeverLoaded: clear choices every launch, delete the folder once (Kev's ruling).
//  Confidence 0.7 (migration pure core is tested; the launch call is verify-by-launch).
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
    nonisolated static func evalMLXBrain(modelID: String, maxTokens: Int, thinkingEnabled: Bool = true) -> MLXBrainProvider {
        if let folder = auditionStore?.directory(for: modelID) {
            auditionLog.notice("eval \(modelID, privacy: .public) loads the imported audition folder, not the hub")
            return MLXBrainProvider(modelDirectory: folder, maxTokens: maxTokens, thinkingEnabled: thinkingEnabled)
        }
        return MLXBrainProvider(modelID: modelID, maxTokens: maxTokens, thinkingEnabled: thinkingEnabled)
    }

    /// At launch, before the first brain is built (1.1): Settings no longer offers auditions,
    /// so every persisted choice (and a never-finished load's marker) is dropped, and ONCE
    /// the imported weights folder is deleted. A `-audition.*` launch argument keeps the
    /// folder and the marker. See `AuditionCleanup`.
    @discardableResult
    nonisolated static func retireAuditions() -> AuditionCleanup.Report {
        let report = AuditionCleanup.run(store: auditionStore)
        if !report.clearedKeys.isEmpty {
            auditionLog.notice("1.1 migration cleared audition choices: \(report.clearedKeys.joined(separator: ","), privacy: .public)")
        }
        return report
    }

    /// A normal quit, even mid-load, is not a crash: keep the audition for next launch.
    nonisolated static func auditionAppQuitting() {
        AuditionSelection.clearPendingLoad()
    }

    /// The live brain's load settled (ready or failed): clear the sentinel only when it was loaded from an
    /// audition folder (review on #452: any ready used to clear any pending load).
    func auditionLoadFinished(sourceKey: String) {
        if AuditionStore.isFolderSourceKey(sourceKey) { AuditionSelection.clearPendingLoad() }
    }

    /// What `tier` should be serving right now, as a provider `sourceKey`: its
    /// audition's folder when one stands in, else nil (the stock hub id).
    nonisolated static func auditionSourceKey(for tier: BrainTier) -> String? {
        AuditionSelection.directory(forTier: tier.rawValue, store: auditionStore).map(AuditionStore.sourceKey(for:))
    }
}
