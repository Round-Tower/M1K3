//
//  ModelStoreLocation.swift
//  M1K3MLX
//
//  Where LLM weights live on disk — and why it is NOT Library/Caches anymore.
//
//  The 2.x-era default parked multi-GB model snapshots under Library/Caches,
//  which macOS treats as purgeable under disk pressure. That is the wrong
//  contract for a 6.7 GB download the app cannot cheaply regenerate — and it
//  bit for real: the production Lil weights vanished on 2026-07-14, and on
//  2026-07-31 the purger ate gemma-4-12B TWICE in one afternoon
//  (log-evidenced: verified-present at 16:51, localMB=0 by 18:34, no app
//  process in between). The embedder — parked in Documents by a different
//  2.x default — never vanished once: the survival pattern that named the
//  bug.
//
//  New home: Application Support (non-purgeable, sandbox-container-local),
//  with the models root excluded from backup — re-downloadable bytes do not
//  belong in Time Machine either. Purgeable was half right; the answer to
//  "big but re-fetchable" is backup exclusion, not purge eligibility.
//
//  Migration is one-time, same-volume (a rename, not a copy), per repo dir,
//  and never clobbers: a repo already present at the destination wins and
//  the legacy copy is left where it is (Caches — the purger's problem now).
//
//  Signed: Kev + claude-fable-5, 2026-07-31, Confidence 0.85 (semantics
//  fixture-pinned in ModelStoreLocationTests; the live migrate-then-load is
//  verify-by-launch). Prior: Unknown
//

import Foundation
import os

private let storeLog = Logger(subsystem: "app.m1k3", category: "model-download")

public enum ModelStoreLocation {
    /// The current LLM download base: Application Support. HubApi appends
    /// `models/<org>/<repo>` beneath whatever base it is given, so this is
    /// the direct replacement for the old Caches base.
    public static func llmBase() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }

    /// The 2.x-era base the purger kept eating. Kept only so migration knows
    /// where to look.
    public static func legacyLLMBase() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }

    public struct MigrationOutcome: Sendable, Equatable {
        public var movedRepos: [String] = []
        public var skippedRepos: [String] = []
    }

    /// One-time store preparation: ensure the Application Support models root
    /// exists with backup exclusion (fresh installs included — review High #2)
    /// and migrate any surviving legacy Caches store across. EXPLICIT and
    /// app-called only (AppEnvironment.init + SelfTest.run): resolving the
    /// base must stay side-effect-free, because `swift test` runs UNSANDBOXED
    /// — a static-let that migrated on first touch would mutate the real
    /// ~/Library of whatever machine runs the tests (review High #1).
    /// Idempotent and cheap after first run (one fileExists guard).
    public static func prepareOnce() {
        _ = prepared
    }

    private static let prepared: Void = {
        guard let current = llmBase() else { return }
        ensureStoreReady(currentBase: current)
        if let legacy = legacyLLMBase() {
            let outcome = migrateLegacyLLMStore(legacyBase: legacy, currentBase: current)
            if !outcome.movedRepos.isEmpty || !outcome.skippedRepos.isEmpty {
                storeLog.notice(
                    "model store migration: moved=\(outcome.movedRepos.count) skipped=\(outcome.skippedRepos.count) → Application Support"
                )
            }
        }
    }()

    /// Create the models root under `currentBase` and mark it excluded from
    /// backup. Runs regardless of legacy presence — a fresh install's first
    /// download must land in an already-excluded tree, not wait for HubApi to
    /// create it with default (backed-up) attributes.
    public static func ensureStoreReady(currentBase: URL) {
        let modelsRoot = currentBase.appendingPathComponent("models")
        try? FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
        excludeFromBackup(modelsRoot)
    }

    /// Move every `models/<org>/<repo>` under `legacyBase` to `currentBase`.
    /// Same-volume rename per repo; a repo already present at the destination
    /// is skipped with its legacy bytes left in place (never clobber, never
    /// destroy). Ensures the destination models root exists and carries
    /// backup exclusion whenever a legacy store was seen.
    @discardableResult
    public static func migrateLegacyLLMStore(legacyBase: URL, currentBase: URL) -> MigrationOutcome {
        var outcome = MigrationOutcome()
        let manager = FileManager.default
        let legacyModels = legacyBase.appendingPathComponent("models")
        guard manager.fileExists(atPath: legacyModels.path) else { return outcome }

        let currentModels = currentBase.appendingPathComponent("models")
        // ensureStoreReady owns creation+exclusion for every install; this
        // repeat is belt-and-braces for direct callers (tests, future tools).
        try? manager.createDirectory(at: currentModels, withIntermediateDirectories: true)
        excludeFromBackup(currentModels)

        for org in subdirectories(of: legacyModels) {
            let destOrg = currentModels.appendingPathComponent(org.lastPathComponent)
            for repo in subdirectories(of: org) {
                let repoID = "\(org.lastPathComponent)/\(repo.lastPathComponent)"
                let dest = destOrg.appendingPathComponent(repo.lastPathComponent)
                if manager.fileExists(atPath: dest.path) {
                    outcome.skippedRepos.append(repoID)
                    continue
                }
                do {
                    try manager.createDirectory(at: destOrg, withIntermediateDirectories: true)
                    try manager.moveItem(at: repo, to: dest)
                    outcome.movedRepos.append(repoID)
                } catch {
                    // A failed move leaves the legacy copy untouched — the
                    // downloader will simply re-fetch into the new base.
                    storeLog.error(
                        "model store migration failed for \(repoID, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            // Drop now-empty legacy org dirs so a later sweep reads clean;
            // best-effort, non-empty dirs (skips/failures) survive.
            if subdirectories(of: org).isEmpty {
                try? manager.removeItem(at: org)
            }
        }
        return outcome
    }

    private static func subdirectories(of url: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }

    private static func excludeFromBackup(_ url: URL) {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }
}
