//
//  AuditionStore.swift
//  M1K3MLX
//
//  Model auditions: any MLX checkpoint already on this Mac (a Hugging Face
//  cache snapshot, a folder someone converted) copied into the app and loaded
//  from its folder in a tier's place, so an A/B is one import and one picker.
//
//  Deliberately BESIDE the pinned store, never in it:
//  - `WeightImport` refuses unpinned repos on purpose (an imported folder is
//    bytes with no provenance). An audition is exactly that, so it lives in
//    its own root, carries no HubApi download metadata, and is loaded with
//    `ModelConfiguration(directory:)`: the downloader is never consulted, so a
//    network fetch can't overwrite it and it can't poison the shipped cache
//    (the 2026-07-16 pre-seed incident).
//  - `LocalModelInventory` / `RetiredWeightsPolicy` walk `models/` only; this
//    root is `M1K3/auditions/`, so the retired-weights sweep never sees it.
//
//  The layout is `<root>/<org>/<repo>/`. mlx-swift-lm names a directory
//  model by its last two path components, so a folder load reports the repo
//  id and every name-keyed decision (tool dialect, KV quantisation, think
//  traits, sliding window) applies as it would to the hub download.
//
//  Symlinks are resolved on the way in: the HF cache's snapshot files point
//  into `blobs/`, and the sandboxed app can only read the source while the
//  open panel's grant lasts. On one APFS volume `copyItem` clones, so the
//  copy costs no extra disk. Every link is checked BEFORE anything is copied or
//  replaced (a snapshot picked on its own points outside the grant), only the
//  top level is copied (what mlx-swift-lm reads; no directory link can loop),
//  a sharded model needs every shard its index names, and the new copy
//  replaces the old one atomically, so a failed import never costs a good one.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-29, Confidence 0.8 (filesystem
//  behaviour test-pinned; the load path is verify-by-launch). Prior: Unknown
//
//  Review: Kev + claude-fable-5.1, 2026-09-29 — #452 review fold: refs/main must be a bare
//  snapshot name (no escaping snapshots/), a name differing only in case is refused
//  (`nameTaken`: one folder on case-insensitive APFS), a subfolder shard says why it's
//  missing, `sourceKey(forRepoID:)` lets the app refuse an import under the live
//  brain, and an org folder that exists in another case is adopted. Confidence 0.85.
//

import Foundation
import os

private let auditionLog = Logger(subsystem: "app.m1k3", category: "model-download")

public struct AuditionModel: Sendable, Equatable, Identifiable {
    public let repoID: String
    public let directory: URL
    public let bytes: Int64
    public var id: String {
        repoID
    }
}

public struct AuditionStore: Sendable {
    public let root: URL

    public enum ImportError: Error, Equatable, LocalizedError {
        case unsafeRepoID(String)
        case notACheckpoint(missing: [String])
        case unreadable([String])
        /// An audition already exists under this name in a different case: on a
        /// case-insensitive volume the two would share one folder.
        case nameTaken(String)

        public var errorDescription: String? {
            switch self {
            case let .unsafeRepoID(id):
                "“\(id)” isn't a model name of the form org/model."
            case let .notACheckpoint(missing):
                "That folder isn't a complete MLX model: it has no \(missing.joined(separator: ", "))."
            case let .unreadable(names):
                "M1K3 couldn't read \(names.joined(separator: ", ")): the files point outside the folder "
                    + "you chose. From the Hugging Face cache, choose the models--org--name folder itself."
            case let .nameTaken(existing):
                "There's already an audition called “\(existing)”. "
                    + "Remove it first, or use its exact name to replace it."
            }
        }
    }

    public init(root: URL) {
        self.root = root
    }

    /// `Application Support/M1K3/auditions`, beside (not inside) the pinned store.
    public static func standard() -> AuditionStore? {
        guard let base = ModelStoreLocation.llmBase() else { return nil }
        return AuditionStore(root: base.appendingPathComponent("M1K3/auditions", isDirectory: true))
    }

    // MARK: - Naming

    /// The model's `org/repo`: from an HF cache folder (`models--org--repo`, at any
    /// depth inside it), else the folder's parent and its own name.
    public static func inferredRepoID(from url: URL) -> String? {
        for component in url.standardizedFileURL.pathComponents.reversed() where component.hasPrefix("models--") {
            let parts = component.dropFirst("models--".count).components(separatedBy: "--")
            guard parts.count >= 2 else { continue }
            return parts[0] + "/" + parts.dropFirst().joined(separator: "--")
        }
        let name = url.lastPathComponent
        let parent = url.deletingLastPathComponent().lastPathComponent
        guard !name.isEmpty, !parent.isEmpty, parent != "/" else { return nil }
        return parent + "/" + name
    }

    // MARK: - Import

    /// Copy the checkpoint at `source` (a model folder, an HF cache model folder or
    /// one of its snapshots) to `<root>/<repoID>`, replacing any earlier import.
    @discardableResult
    public func importFolder(_ source: URL, repoID requested: String) throws -> AuditionModel {
        guard LocalModelInventory.isRemovableRepoID(requested) else { throw ImportError.unsafeRepoID(requested) }
        let repoID = canonicalRepoID(requested)
        if let clash = caseOnlyClash(with: repoID) { throw ImportError.nameTaken(clash) }
        let checkpoint = Self.checkpointDirectory(in: source)
        let plan = try Self.copyPlan(for: checkpoint)
        let missing = Self.missingParts(names: Set(plan.map(\.name)), index: plan.first { $0.name == Self.indexName }?.resolved)
        guard missing.isEmpty else { throw ImportError.notACheckpoint(missing: missing) }

        let fm = FileManager.default
        let destination = directoryURL(for: repoID)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        excludeFromBackup(root)
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(Self.stagingPrefix + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        for item in plan {
            try fm.copyItem(at: item.resolved, to: staging.appendingPathComponent(item.name))
        }
        let copied = Self.missingParts(in: staging)
        guard copied.isEmpty else { throw ImportError.notACheckpoint(missing: copied) }
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
        let model = AuditionModel(repoID: repoID, directory: destination, bytes: Self.directorySize(destination))
        auditionLog.notice("audition imported \(repoID, privacy: .public) (\(model.bytes) bytes)")
        return model
    }

    static let stagingPrefix = ".audition-"
    static let indexName = "model.safetensors.index.json"

    /// Delete staging folders an interrupted import left behind (older than six
    /// hours, so an import running right now is never touched).
    public func sweepStaleStaging(now: Date = Date()) {
        let fm = FileManager.default
        guard let orgs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for org in orgs {
            let entries = (try? fm.contentsOfDirectory(
                at: org, includingPropertiesForKeys: [.contentModificationDateKey], options: []
            )) ?? []
            for entry in entries where entry.lastPathComponent.hasPrefix(Self.stagingPrefix) {
                let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? now
                if now.timeIntervalSince(modified) > 6 * 3600 { try? fm.removeItem(at: entry) }
            }
        }
    }

    /// Model folders are multi-GB and re-importable: keep them out of Time Machine,
    /// as the pinned store is.
    private func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try? target.setResourceValues(values)
    }

    /// Every complete audition, sorted by repo id.
    public func list() -> [AuditionModel] {
        sweepStaleStaging()
        let fm = FileManager.default
        guard let orgs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        var out: [AuditionModel] = []
        for org in orgs where !org.lastPathComponent.hasPrefix(".") {
            guard let repos = try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: nil) else { continue }
            for repo in repos where !repo.lastPathComponent.hasPrefix(".") && Self.missingParts(in: repo).isEmpty {
                out.append(AuditionModel(
                    repoID: "\(org.lastPathComponent)/\(repo.lastPathComponent)",
                    directory: repo, bytes: Self.directorySize(repo)
                ))
            }
        }
        return out.sorted { $0.repoID < $1.repoID }
    }

    /// The folder to load for `repoID`, or nil when it isn't a complete audition.
    public func directory(for repoID: String) -> URL? {
        guard LocalModelInventory.isRemovableRepoID(repoID) else { return nil }
        let dir = directoryURL(for: repoID)
        return Self.missingParts(in: dir).isEmpty ? dir : nil
    }

    public func remove(repoID: String) throws {
        guard LocalModelInventory.isRemovableRepoID(repoID) else { throw ImportError.unsafeRepoID(repoID) }
        let dir = directoryURL(for: repoID)
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try FileManager.default.removeItem(at: dir)
        let org = dir.deletingLastPathComponent()
        if (try? FileManager.default.contentsOfDirectory(atPath: org.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: org)
        }
        auditionLog.notice("audition removed \(repoID, privacy: .public)")
    }

    /// What a provider loaded from `repoID`'s folder reports as its `sourceKey`, so the
    /// app can tell whether an import would land under the live brain.
    public func sourceKey(forRepoID repoID: String) -> String {
        Self.sourceKey(for: directoryURL(for: repoID))
    }

    /// The name an import of `repoID` lands under: its org spelled as an org folder
    /// already on disk that differs only in case, because on case-insensitive APFS the
    /// import lands in that folder anyway and the name has to match what `list()` reports.
    public func canonicalRepoID(_ repoID: String) -> String {
        guard let slash = repoID.firstIndex(of: "/") else { return repoID }
        let org = String(repoID[..<slash])
        let orgs = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        guard !orgs.contains(org),
              let onDisk = orgs.first(where: { !$0.hasPrefix(".") && $0.caseInsensitiveCompare(org) == .orderedSame })
        else { return repoID }
        return onDisk + repoID[slash...]
    }

    /// An existing audition whose name matches `repoID` except in case.
    private func caseOnlyClash(with repoID: String) -> String? {
        let fm = FileManager.default
        let orgs = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        for org in orgs where !org.hasPrefix(".") {
            let repos = (try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(org).path)) ?? []
            for repo in repos where !repo.hasPrefix(".") {
                let existing = "\(org)/\(repo)"
                if existing != repoID, existing.caseInsensitiveCompare(repoID) == .orderedSame { return existing }
            }
        }
        return nil
    }

    private func directoryURL(for repoID: String) -> URL {
        root.appendingPathComponent(repoID, isDirectory: true)
    }

    // MARK: - Checkpoint shape

    /// An HF cache model folder holds the files under `snapshots/<sha>`: take the one
    /// `refs/main` names, else the only (or newest) snapshot. Anything else is itself.
    static func checkpointDirectory(in source: URL) -> URL {
        let fm = FileManager.default
        let snapshots = source.appendingPathComponent("snapshots", isDirectory: true)
        guard fm.fileExists(atPath: snapshots.path) else { return source }
        // refs/main must be a bare snapshot name: "../x" would step outside snapshots/.
        if let ref = try? String(contentsOf: source.appendingPathComponent("refs/main"), encoding: .utf8) {
            let sha = ref.trimmingCharacters(in: .whitespacesAndNewlines)
            let named = snapshots.appendingPathComponent(sha)
            if !sha.isEmpty, !sha.contains("/"), sha != ".", sha != "..", fm.fileExists(atPath: named.path) {
                return named
            }
        }
        let all = (try? fm.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let newest = all.max { lhs, rhs in
            let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return l < r
        }
        return newest ?? source
    }

    /// What a folder lacks to load as an MLX language model: its config, a
    /// tokenizer, at least one weights shard, and every shard its index names.
    /// Empty = loadable-looking.
    static func missingParts(in dir: URL) -> [String] {
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        return missingParts(names: names, index: dir.appendingPathComponent(indexName))
    }

    static func missingParts(names: Set<String>, index: URL?) -> [String] {
        var missing: [String] = []
        if !names.contains("config.json") { missing.append("config.json") }
        if !names.contains("tokenizer.json"), !names.contains("tokenizer_config.json") { missing.append("tokenizer") }
        if !names.contains(where: { $0.hasSuffix(".safetensors") }) { missing.append(".safetensors weights") }
        if let index, let shards = indexedShards(at: index) {
            // Only the top level is copied, so a shard in a subfolder can never arrive.
            missing += shards.subtracting(names).sorted()
                .map { $0.contains("/") ? "\($0) (in a subfolder, which isn't copied)" : $0 }
        }
        return missing
    }

    /// The shard files a `model.safetensors.index.json` names, or nil without one.
    static func indexedShards(at index: URL) -> Set<String>? {
        guard let data = try? Data(contentsOf: index),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let map = object["weight_map"] as? [String: String]
        else { return nil }
        return Set(map.values)
    }

    struct PlannedFile {
        let name: String
        let resolved: URL
    }

    /// The top-level files to copy, each resolved through its symlink. Any file the
    /// app can't read (a link out of the granted folder, a dangling link) fails the
    /// whole import here, before anything is copied or replaced.
    static func copyPlan(for source: URL) throws -> [PlannedFile] {
        let fm = FileManager.default
        var plan: [PlannedFile] = []
        var unreadable: [String] = []
        for name in try fm.contentsOfDirectory(atPath: source.path).sorted() where !name.hasPrefix(".") {
            let resolved = source.appendingPathComponent(name).resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            let exists = fm.fileExists(atPath: resolved.path, isDirectory: &isDirectory)
            if exists, isDirectory.boolValue { continue } // mlx-swift-lm reads the top level only
            guard exists, fm.isReadableFile(atPath: resolved.path) else {
                unreadable.append(name)
                continue
            }
            plan.append(PlannedFile(name: name, resolved: resolved))
        }
        guard unreadable.isEmpty else { throw ImportError.unreadable(unreadable) }
        return plan
    }

    /// What identifies a folder load, as opposed to a hub id: two copies of one repo
    /// share a name, never a folder.
    public static func sourceKey(for directory: URL) -> String {
        "dir:" + directory.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func directorySize(_ dir: URL) -> Int64 {
        guard let walk = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walk {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

/// Which audition, if any, stands in for a tier. UserDefaults per tier, so the
/// Settings picker and a launch argument (`-audition.lil org/repo`, the only
/// override that reaches the sandboxed app on macOS 27) read the same key.
public enum AuditionSelection {
    public static func key(forTier tier: String) -> String {
        "audition.\(tier)"
    }

    public static func repoID(forTier tier: String, defaults: UserDefaults = .standard) -> String? {
        guard let raw = defaults.string(forKey: key(forTier: tier))?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw
    }

    /// Whether `tier`'s choice came in as a launch argument (`-audition.lil org/repo`).
    /// The argument domain outranks the app's own defaults and nothing can clear it, so
    /// picking Stock can't take effect until the app is launched without it.
    public static func isSetAtLaunch(
        tier: String,
        arguments: [String: Any] = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    ) -> Bool {
        arguments[key(forTier: tier)] != nil
    }

    // MARK: The load sentinel

    /// "<tier>" while the live brain loads its audition; cleared when the load settles
    /// (ready or failed), when the brain is switched away, and at a normal quit. Still
    /// set at the next launch = that load never finished (a crash, a trap, jetsam), so
    /// the audition is dropped rather than retried forever.
    public static let pendingLoadKey = "audition.pendingLoad"

    /// Only the brain that is about to become the app's live MLX brain records a pending
    /// load: with Mini selected the launch slot still BUILDS Big's provider (review on
    /// #452), and the deep dive's Big is not the live brain.
    public static func recordsPendingLoad(selectedIsMLX: Bool, buildingSelected: Bool) -> Bool {
        selectedIsMLX && buildingSelected
    }

    public static func recordPendingLoad(tier: String, defaults: UserDefaults = .standard) {
        defaults.set(tier, forKey: pendingLoadKey)
    }

    public static func clearPendingLoad(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: pendingLoadKey)
    }

    /// At launch: drop the audition whose last load never finished. Returns its tier.
    /// A choice passed as a launch argument lives in the argument domain and can't be
    /// removed here; it serves until the argument goes (a dev flag, deliberately).
    @discardableResult
    public static func dropUnfinishedLoad(defaults: UserDefaults = .standard) -> String? {
        guard let tier = defaults.string(forKey: pendingLoadKey) else { return nil }
        defaults.removeObject(forKey: pendingLoadKey)
        defaults.removeObject(forKey: key(forTier: tier))
        return tier
    }

    /// The folder to load in the tier's place: only when one is chosen AND it is
    /// a complete audition on disk. A chosen-but-missing audition falls back to
    /// the stock model rather than failing the brain.
    public static func directory(
        forTier tier: String, store: AuditionStore?, defaults: UserDefaults = .standard
    ) -> URL? {
        guard let store, let id = repoID(forTier: tier, defaults: defaults) else { return nil }
        return store.directory(for: id)
    }
}
