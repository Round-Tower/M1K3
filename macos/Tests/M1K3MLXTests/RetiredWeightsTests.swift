//
//  RetiredWeightsTests.swift
//  M1K3MLXTests
//
//  A re-pin leaves the previous brain's folder on disk unpinned (Lil's
//  2026-09-05 move to DWQ-2510 stranded 2.2 GB). These pin the pure
//  "which folders are retired" decision and the inventory's listing/removal
//  against a temp download base — no network, no MLX. Issue #222.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-05, Confidence 0.85, Prior: none.

import Foundation
@testable import M1K3MLX
import Testing

struct RetiredWeightsTests {
    private func makeBase() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("m1k3-retired-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func seed(_ id: String, bytes: Int, under base: URL) throws {
        let dir = base.appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0, count: bytes).write(to: dir.appendingPathComponent("model.safetensors"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
    }

    @Test("a folder is retired only when nothing shipped, pinned, or loaded claims it; biggest first")
    func policyPicksUnclaimedFolders() {
        let installed = [
            InstalledWeights(repoID: "mlx-community/Qwen3-4B-Instruct-2507-4bit", bytes: 2_263_022_417),
            InstalledWeights(repoID: "mlx-community/Qwen3-4B-Instruct-2507-4bit-DWQ-2510", bytes: 2_263_000_000),
            InstalledWeights(repoID: "mlx-community/gemma-4-12B-it-4bit", bytes: 6_772_000_000),
            InstalledWeights(repoID: "mlx-community/Qwen3.8-27B-4bit", bytes: 16_070_000_000),
            InstalledWeights(repoID: "mlx-community/Llama-3.2-1B-Instruct-4bit", bytes: 700_000_000),
        ]
        let keep: Set = [
            "mlx-community/Qwen3-4B-Instruct-2507-4bit-DWQ-2510", "mlx-community/gemma-4-12B-it-4bit",
            "mlx-community/Qwen3.8-27B-4bit", // loaded right now (an eval override) — never offered
        ]
        let retired = RetiredWeightsPolicy.retired(installed: installed, keep: keep)
        #expect(retired.map(\.repoID) == [
            "mlx-community/Qwen3-4B-Instruct-2507-4bit", "mlx-community/Llama-3.2-1B-Instruct-4bit",
        ])
        #expect(RetiredWeightsPolicy.totalBytes(retired) == 2_263_022_417 + 700_000_000)
        #expect(RetiredWeightsPolicy.retired(installed: [], keep: keep).isEmpty)
    }

    @Test("the policy never offers a kept id even when its folder is the only one")
    func policyNeverOffersKept() {
        let only = [InstalledWeights(repoID: "a/b", bytes: 1)]
        #expect(RetiredWeightsPolicy.retired(installed: only, keep: ["a/b"]).isEmpty)
    }

    @Test("the inventory lists every org/repo folder with its byte size, skipping dot-folders")
    func inventoryListsFolders() throws {
        let base = try makeBase()
        try seed("mlx-community/Old-4bit", bytes: 4096, under: base)
        try seed("mlx-community/New-4bit", bytes: 1024, under: base)
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("models/mlx-community/.m1k3-receipts"), withIntermediateDirectories: true
        )
        let listed = LocalModelInventory(downloadBase: base).installedWeights()
        #expect(listed.map(\.repoID).sorted() == ["mlx-community/New-4bit", "mlx-community/Old-4bit"])
        let old = try #require(listed.first { $0.repoID == "mlx-community/Old-4bit" })
        #expect(old.bytes == Int64(4096 + 2)) // model.safetensors + "{}" config
    }

    @Test("removing a retired folder deletes exactly that folder")
    func inventoryRemovesOneFolder() throws {
        let base = try makeBase()
        try seed("mlx-community/Old-4bit", bytes: 16, under: base)
        try seed("mlx-community/New-4bit", bytes: 16, under: base)
        let inventory = LocalModelInventory(downloadBase: base)
        try inventory.remove(modelID: "mlx-community/Old-4bit")
        #expect(!inventory.isInstalled(modelID: "mlx-community/Old-4bit"))
        #expect(inventory.isInstalled(modelID: "mlx-community/New-4bit"))
        #expect(inventory.installedWeights().map(\.repoID) == ["mlx-community/New-4bit"])
    }

    @Test("removing a folder also drops its sibling integrity receipt")
    func removeDropsReceipt() throws {
        let base = try makeBase()
        let fm = FileManager.default
        let repo = base.appendingPathComponent("models/org/Old", isDirectory: true)
        try fm.createDirectory(at: repo, withIntermediateDirectories: true)
        let receipt = base.appendingPathComponent("models/org/.m1k3-receipts/Old.receipt")
        try fm.createDirectory(at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: receipt)
        try LocalModelInventory(downloadBase: base).remove(modelID: "org/Old")
        #expect(!fm.fileExists(atPath: repo.path))
        #expect(!fm.fileExists(atPath: receipt.path))
    }

    @Test("a malformed repo id is refused before any filesystem call")
    func removeRefusesMalformedIDs() throws {
        let base = try makeBase()
        let inventory = LocalModelInventory(downloadBase: base)
        for bad in ["../../Documents", "/etc", "bare", "org/../x", "org/.hidden", "", "a/b/c", "org/"] {
            #expect(!LocalModelInventory.isRemovableRepoID(bad), "\(bad) should be refused")
            #expect(throws: LocalModelInventory.UnsafeRepoIDError.self) { try inventory.remove(modelID: bad) }
        }
        #expect(LocalModelInventory.isRemovableRepoID("mlx-community/Qwen3-4B-Instruct-2507-4bit"))
    }

    @Test("an empty inventory lists nothing and removal of a missing folder is not an error")
    func inventoryEmpty() throws {
        let base = try makeBase()
        let inventory = LocalModelInventory(downloadBase: base)
        #expect(inventory.installedWeights().isEmpty)
        try inventory.remove(modelID: "mlx-community/Never-Here")
    }
}
