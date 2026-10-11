//
//  LocalModelInventoryTests.swift
//  M1K3MLXTests
//
//  Pins the on-disk brain detection against a temp download base: a model counts
//  as installed only once its weights (*.safetensors) are present, so a partial
//  or metadata-only download never reads as "ready". The path layout is HubApi's
//  own (downloadBase/models/<id>) — the same one the downloader writes — so these
//  tests double as a guard that the convention hasn't moved under us.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-12, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-opus-5.5, 2026-10-11 (pre-push review fold) — B4 installState complete/partial/absent against a pin. Confidence 0.85.

import Foundation
@testable import M1K3MLX
import Testing

struct LocalModelInventoryTests {
    /// A throwaway download base; caller seeds model folders under it.
    private func makeBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("m1k3-inventory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Seed `<base>/models/<id>/<files>` — the HubApi layout.
    private func seed(_ id: String, files: [String], under base: URL) throws {
        let dir = base.appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in files {
            try Data("x".utf8).write(to: dir.appendingPathComponent(file))
        }
    }

    @Test("a model with weights on disk reads as installed")
    func installedWhenWeightsPresent() throws {
        let base = try makeBase()
        try seed("mlx-community/Qwen3.5-2B-4bit", files: ["config.json", "model.safetensors"], under: base)
        let inventory = LocalModelInventory(downloadBase: base)
        #expect(inventory.isInstalled(modelID: "mlx-community/Qwen3.5-2B-4bit"))
    }

    @Test("an absent model reads as not installed")
    func notInstalledWhenAbsent() throws {
        let inventory = try LocalModelInventory(downloadBase: makeBase())
        #expect(!inventory.isInstalled(modelID: "mlx-community/Qwen3.5-9B-4bit"))
    }

    @Test("a metadata-only (no weights) folder is NOT installed — partial download")
    func notInstalledWhenWeightsMissing() throws {
        let base = try makeBase()
        // The index manifest without the actual *.safetensors shards = interrupted.
        try seed("mlx-community/Qwen3.5-9B-4bit",
                 files: ["config.json", "model.safetensors.index.json"], under: base)
        let inventory = LocalModelInventory(downloadBase: base)
        #expect(!inventory.isInstalled(modelID: "mlx-community/Qwen3.5-9B-4bit"))
    }

    @Test("sharded weights (model-00001-of-...) count as installed")
    func installedWhenSharded() throws {
        let base = try makeBase()
        try seed("mlx-community/gemma-4-e4b-it-4bit",
                 files: ["config.json", "model-00001-of-00002.safetensors"], under: base)
        let inventory = LocalModelInventory(downloadBase: base)
        #expect(inventory.isInstalled(modelID: "mlx-community/gemma-4-e4b-it-4bit"))
    }

    // MARK: - B4: complete vs partial against the pinned manifest

    private func seedSized(_ id: String, files: [String: Int], under base: URL) throws {
        let dir = base.appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, size) in files {
            try Data(count: size).write(to: dir.appendingPathComponent(name))
        }
    }

    private static let pin = WeightIntegrity.Pin(revision: String(repeating: "a", count: 40), files: [
        "config.json": .init(size: 10, sha256: "x"),
        "model-00001-of-00002.safetensors": .init(size: 100, sha256: "y"),
        "model-00002-of-00002.safetensors": .init(size: 200, sha256: "z"),
    ])

    @Test("B4: every pinned weight shard at its pinned size reads as complete")
    func completeAgainstPin() throws {
        let base = try makeBase()
        try seedSized("a/b", files: ["config.json": 12, "model-00001-of-00002.safetensors": 100,
                                     "model-00002-of-00002.safetensors": 200], under: base)
        #expect(LocalModelInventory(downloadBase: base).installState(modelID: "a/b", pin: Self.pin) == .complete)
    }

    @Test("B4: one shard of two is partial, not downloaded — the cancelled multi-shard fetch")
    func missingShardIsPartial() throws {
        let base = try makeBase()
        try seedSized("a/b", files: ["config.json": 10, "model-00001-of-00002.safetensors": 100], under: base)
        let inventory = LocalModelInventory(downloadBase: base)
        #expect(inventory.installState(modelID: "a/b", pin: Self.pin) == .partial)
        // The old any-safetensors check still says "installed": the manager no longer trusts it.
        #expect(inventory.isInstalled(modelID: "a/b"))
    }

    @Test("B4: a short shard (interrupted mid-file) is partial")
    func shortShardIsPartial() throws {
        let base = try makeBase()
        try seedSized("a/b", files: ["config.json": 10, "model-00001-of-00002.safetensors": 100,
                                     "model-00002-of-00002.safetensors": 150], under: base)
        #expect(LocalModelInventory(downloadBase: base).installState(modelID: "a/b", pin: Self.pin) == .partial)
    }

    @Test("B4: nothing, or an empty folder, is absent; an unpinned repo falls back to any weights")
    func absentAndUnpinned() throws {
        let base = try makeBase()
        let inventory = LocalModelInventory(downloadBase: base)
        #expect(inventory.installState(modelID: "a/b", pin: Self.pin) == .absent)
        try seedSized("c/d", files: [:], under: base)
        #expect(inventory.installState(modelID: "c/d", pin: Self.pin) == .absent)
        try seedSized("e/f", files: ["model.safetensors": 5], under: base)
        #expect(inventory.installState(modelID: "e/f", pin: nil) == .complete)
        try seedSized("g/h", files: ["config.json": 5], under: base)
        #expect(inventory.installState(modelID: "g/h", pin: nil) == .partial)
    }
}
