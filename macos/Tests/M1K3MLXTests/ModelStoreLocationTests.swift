//
//  ModelStoreLocationTests.swift
//  M1K3MLXTests
//
//  Pins the weights-out-of-Caches move (2026-07-31). LLM weights lived in
//  Library/Caches — which macOS purges under disk pressure, and DID: the
//  cache-purge class ate the production Lil weights (07-14), and on 07-31 ate
//  gemma-4-12B twice in one afternoon (verified-present 16:51 → localMB=0 at
//  18:34, log-evidenced). The embedder, parked in Documents, never vanished —
//  the survival pattern that named the bug. New home: Application Support
//  (non-purgeable) with backup exclusion (re-downloadable bytes don't belong
//  in Time Machine), plus a one-time same-volume migration of whatever
//  survives in Caches.
//
//  Signed: Kev + claude-fable-5, 2026-07-31, Confidence 0.85 (migration
//  semantics fixture-pinned on temp dirs; the live-fire migrate + load is the
//  named on-device verify). Prior: Unknown
//

import Foundation
@testable import M1K3MLX
import Testing

struct ModelStoreLocationTests {
    private func makeBase() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("modelstore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func plantRepo(_ base: URL, org: String, repo: String, marker: String) throws {
        let dir = base.appendingPathComponent("models/\(org)/\(repo)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(marker.utf8).write(to: dir.appendingPathComponent("model.safetensors"))
    }

    // MARK: - The base itself

    @Test("the LLM base lives in Application Support, never Caches")
    func baseIsApplicationSupport() throws {
        let base = try #require(ModelStoreLocation.llmBase())
        #expect(base.path.contains("Application Support"))
        #expect(!base.path.contains("/Caches/"))
    }

    @Test("the legacy base is the old Caches root — the purge victim")
    func legacyBaseIsCaches() throws {
        let legacy = try #require(ModelStoreLocation.legacyLLMBase())
        #expect(legacy.path.contains("/Caches") || legacy.path.hasSuffix("Caches"))
    }

    // MARK: - Migration

    @Test("legacy repos move wholesale to the new base — same-volume, bytes intact")
    func migratesLegacyRepos() throws {
        let legacy = try makeBase()
        let current = try makeBase()
        try plantRepo(legacy, org: "mlx-community", repo: "gemma-4-12B-it-4bit", marker: "big")
        try plantRepo(legacy, org: "mlx-community", repo: "Qwen3-4B-Instruct-2507-4bit", marker: "lil")
        defer {
            try? FileManager.default.removeItem(at: legacy)
            try? FileManager.default.removeItem(at: current)
        }

        let outcome = ModelStoreLocation.migrateLegacyLLMStore(legacyBase: legacy, currentBase: current)

        #expect(outcome.movedRepos.sorted() == [
            "mlx-community/Qwen3-4B-Instruct-2507-4bit", "mlx-community/gemma-4-12B-it-4bit",
        ])
        let moved = current.appendingPathComponent("models/mlx-community/gemma-4-12B-it-4bit/model.safetensors")
        #expect(try String(data: Data(contentsOf: moved), encoding: .utf8) == "big")
        // The legacy repo dirs are gone (moved, not copied).
        #expect(!FileManager.default.fileExists(
            atPath: legacy.appendingPathComponent("models/mlx-community/gemma-4-12B-it-4bit").path
        ))
    }

    @Test("a repo already present at the destination is SKIPPED — never clobbered, legacy bytes left in place")
    func destinationWins() throws {
        let legacy = try makeBase()
        let current = try makeBase()
        try plantRepo(legacy, org: "org", repo: "model", marker: "legacy-copy")
        try plantRepo(current, org: "org", repo: "model", marker: "current-copy")
        defer {
            try? FileManager.default.removeItem(at: legacy)
            try? FileManager.default.removeItem(at: current)
        }

        let outcome = ModelStoreLocation.migrateLegacyLLMStore(legacyBase: legacy, currentBase: current)

        #expect(outcome.movedRepos.isEmpty)
        #expect(outcome.skippedRepos == ["org/model"])
        let kept = current.appendingPathComponent("models/org/model/model.safetensors")
        #expect(try String(data: Data(contentsOf: kept), encoding: .utf8) == "current-copy")
        // Legacy copy untouched — verify-then-preserve; the purger owns Caches.
        let legacyKept = legacy.appendingPathComponent("models/org/model/model.safetensors")
        #expect(try String(data: Data(contentsOf: legacyKept), encoding: .utf8) == "legacy-copy")
    }

    @Test("no legacy store at all is a clean no-op")
    func absentLegacyIsNoOp() throws {
        let legacy = FileManager.default.temporaryDirectory
            .appendingPathComponent("modelstore-absent-\(UUID().uuidString)")
        let current = try makeBase()
        defer { try? FileManager.default.removeItem(at: current) }

        let outcome = ModelStoreLocation.migrateLegacyLLMStore(legacyBase: legacy, currentBase: current)

        #expect(outcome.movedRepos.isEmpty)
        #expect(outcome.skippedRepos.isEmpty)
    }

    @Test("migration is idempotent — a second run finds nothing to do")
    func idempotent() throws {
        let legacy = try makeBase()
        let current = try makeBase()
        try plantRepo(legacy, org: "org", repo: "model", marker: "x")
        defer {
            try? FileManager.default.removeItem(at: legacy)
            try? FileManager.default.removeItem(at: current)
        }

        _ = ModelStoreLocation.migrateLegacyLLMStore(legacyBase: legacy, currentBase: current)
        let second = ModelStoreLocation.migrateLegacyLLMStore(legacyBase: legacy, currentBase: current)

        #expect(second.movedRepos.isEmpty)
        #expect(second.skippedRepos.isEmpty)
    }

    @Test("the migrated models root is excluded from backup — re-downloadable GBs stay out of Time Machine")
    func backupExclusionSet() throws {
        let legacy = try makeBase()
        let current = try makeBase()
        try plantRepo(legacy, org: "org", repo: "model", marker: "x")
        defer {
            try? FileManager.default.removeItem(at: legacy)
            try? FileManager.default.removeItem(at: current)
        }

        _ = ModelStoreLocation.migrateLegacyLLMStore(legacyBase: legacy, currentBase: current)

        let modelsRoot = current.appendingPathComponent("models")
        let values = try modelsRoot.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }
}
