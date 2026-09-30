//
//  AuditionStoreTests.swift
//  M1K3MLXTests
//
//  Pins the audition store: any MLX checkpoint already on the machine (a
//  Hugging Face cache snapshot, a converted folder) can be copied beside the
//  pinned store and loaded from its folder for an A/B, without ever touching
//  the pinned store or HubApi's download metadata.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-29, Confidence 0.85 (real filesystem,
//  symlinked HF-cache layout included). Prior: Unknown
//

import Foundation
@testable import M1K3MLX
import MLXLMCommon
import Testing

struct AuditionStoreTests {
    private func tempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m1k3-audition-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A loadable-looking checkpoint: config, tokenizer, one weights shard.
    private func seedCheckpoint(at dir: URL, extra: [String] = []) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"] + extra {
            try Data("{\"f\":\"\(file)\"}".utf8).write(to: dir.appendingPathComponent(file))
        }
    }

    /// The Hugging Face cache layout: `models--org--repo/snapshots/<sha>/<file>`
    /// where every file is a symlink into `blobs/`, and `refs/main` names the sha.
    private func seedHFCache(org: String, repo: String, under root: URL, sha: String = "abc123") throws -> URL {
        let fm = FileManager.default
        let model = root.appendingPathComponent("models--\(org)--\(repo)", isDirectory: true)
        let blobs = model.appendingPathComponent("blobs", isDirectory: true)
        let snapshot = model.appendingPathComponent("snapshots/\(sha)", isDirectory: true)
        try fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        try fm.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try fm.createDirectory(at: model.appendingPathComponent("refs"), withIntermediateDirectories: true)
        try Data(sha.utf8).write(to: model.appendingPathComponent("refs/main"))
        for file in ["config.json", "tokenizer.json", "model.safetensors"] {
            let blob = blobs.appendingPathComponent("blob-\(file)")
            try Data("{\"blob\":\"\(file)\"}".utf8).write(to: blob)
            try fm.createSymbolicLink(
                atPath: snapshot.appendingPathComponent(file).path,
                withDestinationPath: "../../blobs/blob-\(file)"
            )
        }
        return model
    }

    // MARK: - Naming

    @Test("the repo id comes from the HF cache folder name, at any depth inside it")
    func repoIDFromHFCache() {
        let model = URL(fileURLWithPath: "/x/hub/models--mlx-community--LFM2.5-2.6B-4bit")
        #expect(AuditionStore.inferredRepoID(from: model) == "mlx-community/LFM2.5-2.6B-4bit")
        let snapshot = model.appendingPathComponent("snapshots/abc123")
        #expect(AuditionStore.inferredRepoID(from: snapshot) == "mlx-community/LFM2.5-2.6B-4bit")
    }

    @Test("a plain folder names itself parent/folder — what a folder load calls the model")
    func repoIDFromPlainFolder() {
        let dir = URL(fileURLWithPath: "/x/converted/ornith-ai/Ornith-1.5-9B-MLX-4bit")
        #expect(AuditionStore.inferredRepoID(from: dir) == "ornith-ai/Ornith-1.5-9B-MLX-4bit")
    }

    // MARK: - Import

    @Test("importing an HF cache snapshot resolves its symlinks into real files")
    func importsHFCacheSnapshot() throws {
        let cache = try tempDir("hf")
        let model = try seedHFCache(org: "mlx-community", repo: "Tiny-4bit", under: cache)
        let store = try AuditionStore(root: tempDir("store"))

        let imported = try store.importFolder(model, repoID: "mlx-community/Tiny-4bit")

        #expect(imported.repoID == "mlx-community/Tiny-4bit")
        #expect(imported.directory.path.hasSuffix("mlx-community/Tiny-4bit"))
        let config = imported.directory.appendingPathComponent("config.json")
        let kind = try FileManager.default.attributesOfItem(atPath: config.path)[.type] as? FileAttributeType
        #expect(kind == .typeRegular) // a copy, not a dangling symlink into another tree
        #expect(try String(contentsOf: config, encoding: .utf8).contains("config.json"))
        #expect(store.list().map(\.repoID) == ["mlx-community/Tiny-4bit"])
    }

    @Test("a plain checkpoint folder imports and lists")
    func importsPlainFolder() throws {
        let source = try tempDir("src").appendingPathComponent("org/Model-4bit")
        try seedCheckpoint(at: source)
        let store = try AuditionStore(root: tempDir("store"))
        _ = try store.importFolder(source, repoID: "org/Model-4bit")
        #expect(store.directory(for: "org/Model-4bit") != nil)
        #expect(store.directory(for: "org/Other") == nil)
    }

    @Test("a folder with no weights, config or tokenizer is refused and nothing lands")
    func refusesIncompleteFolder() throws {
        let source = try tempDir("src")
        try Data("{}".utf8).write(to: source.appendingPathComponent("config.json"))
        let root = try tempDir("store")
        let store = AuditionStore(root: root)
        #expect(throws: AuditionStore.ImportError.self) {
            try store.importFolder(source, repoID: "org/Broken")
        }
        #expect(store.list().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("org/Broken").path))
    }

    @Test("a malformed repo id is refused before any file is copied")
    func refusesUnsafeRepoID() throws {
        let source = try tempDir("src")
        try seedCheckpoint(at: source)
        let store = try AuditionStore(root: tempDir("store"))
        for bad in ["../escape", "/abs/path", "bare", "org/.hidden", "a/b/c"] {
            #expect(throws: AuditionStore.ImportError.self) { try store.importFolder(source, repoID: bad) }
        }
    }

    @Test("re-importing the same repo replaces it rather than merging two checkpoints")
    func reimportReplaces() throws {
        let store = try AuditionStore(root: tempDir("store"))
        let first = try tempDir("a")
        try seedCheckpoint(at: first, extra: ["stale.safetensors"])
        _ = try store.importFolder(first, repoID: "org/M")
        let second = try tempDir("b")
        try seedCheckpoint(at: second)
        let imported = try store.importFolder(second, repoID: "org/M")
        #expect(!FileManager.default.fileExists(atPath: imported.directory.appendingPathComponent("stale.safetensors").path))
    }

    @Test("remove deletes one audition and leaves the rest")
    func removeOne() throws {
        let store = try AuditionStore(root: tempDir("store"))
        for id in ["org/A", "org/B"] {
            let src = try tempDir("src")
            try seedCheckpoint(at: src)
            _ = try store.importFolder(src, repoID: id)
        }
        try store.remove(repoID: "org/A")
        #expect(store.list().map(\.repoID) == ["org/B"])
        try store.remove(repoID: "org/B")
        #expect(store.list().isEmpty)
        // The last audition in an org takes the empty org folder with it.
        #expect(!FileManager.default.fileExists(atPath: store.root.appendingPathComponent("org").path))
    }

    @Test("a weights link pointing outside what was granted fails the import, and the earlier import survives")
    func danglingWeightsLinkFailsAndKeepsTheOld() throws {
        let store = try AuditionStore(root: tempDir("store"))
        let good = try tempDir("good")
        try seedCheckpoint(at: good)
        _ = try store.importFolder(good, repoID: "org/M")

        // A snapshot picked on its own: its links lead to blobs the sandbox can't read.
        let snapshot = try tempDir("snap")
        for file in ["config.json", "tokenizer.json"] {
            try Data("{}".utf8).write(to: snapshot.appendingPathComponent(file))
        }
        try FileManager.default.createSymbolicLink(
            atPath: snapshot.appendingPathComponent("model.safetensors").path,
            withDestinationPath: "../../blobs/nowhere"
        )
        #expect(throws: AuditionStore.ImportError.self) { try store.importFolder(snapshot, repoID: "org/M") }
        #expect(store.directory(for: "org/M") != nil) // the good copy is still there
    }

    @Test("a sharded model is complete only when every shard its index names is present")
    func shardIndexMustBeSatisfied() throws {
        let source = try tempDir("sharded")
        try seedCheckpoint(at: source)
        try FileManager.default.removeItem(at: source.appendingPathComponent("model.safetensors"))
        try Data("x".utf8).write(to: source.appendingPathComponent("model-00001-of-00002.safetensors"))
        let index = #"{"weight_map":{"a":"model-00001-of-00002.safetensors","b":"model-00002-of-00002.safetensors"}}"#
        try Data(index.utf8).write(to: source.appendingPathComponent("model.safetensors.index.json"))
        #expect(AuditionStore.missingParts(in: source) == ["model-00002-of-00002.safetensors"])
        let store = try AuditionStore(root: tempDir("store"))
        #expect(throws: AuditionStore.ImportError.self) { try store.importFolder(source, repoID: "org/Sharded") }
    }

    @Test("a shard the index places in a subfolder says subfolders aren't copied")
    func subfolderShardIsNamedAsSuch() throws {
        let source = try tempDir("subshard")
        try seedCheckpoint(at: source)
        let index = #"{"weight_map":{"a":"model.safetensors","b":"parts/x.safetensors"}}"#
        try Data(index.utf8).write(to: source.appendingPathComponent("model.safetensors.index.json"))
        #expect(AuditionStore.missingParts(in: source) == ["parts/x.safetensors (in a subfolder, which isn't copied)"])
    }

    @Test("a refs/main that isn't a plain snapshot name can't point outside snapshots/")
    func refsMainCannotEscape() throws {
        let cache = try tempDir("refs")
        let model = try seedHFCache(org: "org", repo: "Esc", under: cache)
        // A folder beside the cache that looks like a checkpoint.
        try seedCheckpoint(at: model.appendingPathComponent("outside"))
        try Data("../outside".utf8).write(to: model.appendingPathComponent("refs/main"))
        let picked = AuditionStore.checkpointDirectory(in: model)
        #expect(picked.deletingLastPathComponent().lastPathComponent == "snapshots")
        #expect(picked.lastPathComponent == "abc123")
    }

    @Test("a name that differs from an existing audition only by case is refused, not merged into it")
    func caseOnlyNameClashIsRefused() throws {
        let source = try tempDir("case")
        try seedCheckpoint(at: source)
        let store = try AuditionStore(root: tempDir("store"))
        try store.importFolder(source, repoID: "org/Model")
        #expect(throws: AuditionStore.ImportError.nameTaken("org/Model")) {
            try store.importFolder(source, repoID: "Org/model")
        }
        try store.importFolder(source, repoID: "org/Model") // the same name still re-imports
    }

    @Test("an org that exists in another case is adopted, so the name matches the folder it lands in")
    func existingOrgCaseIsAdopted() throws {
        let source = try tempDir("orgcase")
        try seedCheckpoint(at: source)
        let store = try AuditionStore(root: tempDir("store"))
        try store.importFolder(source, repoID: "Org/Other")
        let model = try store.importFolder(source, repoID: "org/M")
        #expect(model.repoID == "Org/M")
        #expect(store.list().map(\.repoID) == ["Org/M", "Org/Other"])
    }

    @Test("the canonical name is what an import would land under, org case included")
    func canonicalNameAdoptsOrgCase() throws {
        let source = try tempDir("canon")
        try seedCheckpoint(at: source)
        let store = try AuditionStore(root: tempDir("store"))
        try store.importFolder(source, repoID: "Org/Other")
        #expect(store.canonicalRepoID("org/M") == "Org/M")
        #expect(store.canonicalRepoID("other/M") == "other/M")
    }

    @Test("a repo id's source key is the one its folder load reports")
    func repoSourceKeyMatchesTheFolderLoad() throws {
        let store = try AuditionStore(root: tempDir("store"))
        #expect(store.sourceKey(forRepoID: "org/M")
            == AuditionStore.sourceKey(for: store.root.appendingPathComponent("org/M", isDirectory: true)))
    }

    @Test("only the top level is copied: a directory link can't loop, extra folders don't ride along")
    func copiesTopLevelOnly() throws {
        let source = try tempDir("loop")
        try seedCheckpoint(at: source)
        try FileManager.default.createSymbolicLink(
            atPath: source.appendingPathComponent("loop").path, withDestinationPath: "."
        )
        let store = try AuditionStore(root: tempDir("store"))
        let imported = try store.importFolder(source, repoID: "org/Loop")
        let names = try FileManager.default.contentsOfDirectory(atPath: imported.directory.path).sorted()
        #expect(names == ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"])
    }

    @Test("a staging folder left by a crash is swept, a fresh one is not")
    func sweepsStaleStaging() throws {
        let root = try tempDir("store")
        let org = root.appendingPathComponent("org")
        let stale = org.appendingPathComponent(".audition-old")
        let fresh = org.appendingPathComponent(".audition-new")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-7 * 3600)], ofItemAtPath: stale.path
        )
        AuditionStore(root: root).sweepStaleStaging()
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    // MARK: - Selection

    @Test("a tier's audition is read from defaults, and only when its folder is really there")
    func selectionNeedsTheFolder() throws {
        let defaults = try #require(UserDefaults(suiteName: "audition-\(UUID().uuidString)"))
        let store = try AuditionStore(root: tempDir("store"))
        #expect(AuditionSelection.directory(forTier: "lil", store: store, defaults: defaults) == nil)

        defaults.set("org/Gone", forKey: AuditionSelection.key(forTier: "lil"))
        #expect(AuditionSelection.directory(forTier: "lil", store: store, defaults: defaults) == nil)

        let src = try tempDir("src")
        try seedCheckpoint(at: src)
        _ = try store.importFolder(src, repoID: "org/Here")
        defaults.set("org/Here", forKey: AuditionSelection.key(forTier: "lil"))
        #expect(AuditionSelection.directory(forTier: "lil", store: store, defaults: defaults)?
            .path.hasSuffix("org/Here") == true)
        #expect(AuditionSelection.directory(forTier: "big", store: store, defaults: defaults) == nil)
    }

    // MARK: - Loading from the folder

    @Test("a folder load is named org/repo and reads its dialect from the folder, not the store")
    func folderLoadReadsItsOwnConfig() throws {
        // No family word in the name: only the folder's config.json can say lfm2.
        let dir = try tempDir("load").appendingPathComponent("acme/Mystery-1B", isDirectory: true)
        try seedCheckpoint(at: dir)
        try Data(#"{"model_type":"lfm2"}"#.utf8).write(to: dir.appendingPathComponent("config.json"))

        let provider = MLXBrainProvider(modelDirectory: dir)

        #expect(provider.modelIdentifier == "acme/Mystery-1B")
        #expect(provider.configDirectory == dir)
        #expect(provider.resolvedToolCallFormat == .lfm2)
    }

    @Test("a hub-id load keeps reading the pinned store (no folder)")
    func hubLoadHasNoFolder() {
        let provider = MLXBrainProvider(modelID: "mlx-community/Qwen3-4B-Instruct-2507-4bit-DWQ-2510")
        #expect(provider.configDirectory == nil)
        #expect(provider.sourceKey == "mlx-community/Qwen3-4B-Instruct-2507-4bit-DWQ-2510")
    }

    @Test("a folder load's source key is its folder, so a same-named audition is never mistaken for the stock model")
    func folderSourceKeyIsTheFolder() throws {
        let dir = try tempDir("key").appendingPathComponent("mlx-community/Qwen3-4B-Instruct-2507-4bit-DWQ-2510")
        try seedCheckpoint(at: dir)
        let provider = MLXBrainProvider(modelDirectory: dir)
        #expect(provider.modelIdentifier == "mlx-community/Qwen3-4B-Instruct-2507-4bit-DWQ-2510")
        #expect(provider.sourceKey == AuditionStore.sourceKey(for: dir))
        #expect(provider.sourceKey != provider.modelIdentifier)
    }

    // MARK: - The load sentinel (review on #452)

    private func freshDefaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "audition-sentinel-\(UUID().uuidString)"))
    }

    @Test("an audition load that never reached ready is dropped at the next launch, once")
    func unfinishedLoadIsDropped() throws {
        let defaults = try freshDefaults()
        defaults.set("org/Crashy", forKey: AuditionSelection.key(forTier: "big"))
        AuditionSelection.recordPendingLoad(tier: "big", defaults: defaults)
        #expect(AuditionSelection.dropUnfinishedLoad(defaults: defaults) == "big")
        #expect(AuditionSelection.repoID(forTier: "big", defaults: defaults) == nil)
        #expect(AuditionSelection.dropUnfinishedLoad(defaults: defaults) == nil) // cleared
    }

    @Test("a finished or abandoned load leaves the choice alone")
    func finishedOrAbandonedLoadKeepsTheChoice() throws {
        let defaults = try freshDefaults()
        defaults.set("org/Fine", forKey: AuditionSelection.key(forTier: "lil"))
        AuditionSelection.recordPendingLoad(tier: "lil", defaults: defaults)
        AuditionSelection.clearPendingLoad(defaults: defaults) // .ready, or a switch away
        #expect(AuditionSelection.dropUnfinishedLoad(defaults: defaults) == nil)
        #expect(AuditionSelection.repoID(forTier: "lil", defaults: defaults) == "org/Fine")
    }

    @Test("only an MLX brain that is really about to load records a pending load")
    func onlyALiveMLXLoadRecords() {
        // Mini selected: the launch slot still BUILDS Big's provider, but nothing loads it.
        #expect(!AuditionSelection.recordsPendingLoad(selectedIsMLX: false, buildingSelected: false))
        #expect(!AuditionSelection.recordsPendingLoad(selectedIsMLX: true, buildingSelected: false)) // the dive's Big
        #expect(AuditionSelection.recordsPendingLoad(selectedIsMLX: true, buildingSelected: true))
    }

    @Test("a choice passed at launch is reported as one, so the pane can say why Stock didn't take")
    func launchArgumentChoiceIsVisible() {
        #expect(AuditionSelection.isSetAtLaunch(tier: "lil", arguments: ["audition.lil": "org/M"]))
        #expect(!AuditionSelection.isSetAtLaunch(tier: "big", arguments: ["audition.lil": "org/M"]))
        #expect(!AuditionSelection.isSetAtLaunch(tier: "lil", arguments: [:]))
    }
}
