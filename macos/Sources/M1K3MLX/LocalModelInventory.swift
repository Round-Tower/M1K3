//
//  LocalModelInventory.swift
//  M1K3MLX
//
//  "Is this brain already on disk?" — so the UI can say "ready" instead of
//  offering a re-download for weights the user already has. The sandbox flip
//  exposed the need: nothing here checked disk, so every brain read as
//  not-downloaded even when its files were sitting in the container.
//
//  Uses HubApi's OWN path resolution (downloadBase/models/<id>) — the exact
//  layout HubApiDownloader writes to — so detection and download can never drift.
//  A model counts as installed only when its folder holds a weights file
//  (*.safetensors); a half-finished or metadata-only download reads as NOT
//  installed, so the hint never lies about a partial fetch.
//
//  Pure Foundation + Hub path math over an injectable base, so it's unit-tested
//  against a temp directory with no network and no MLX runtime.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-12, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-09-05 — `installedWeights()` (every
//  org/repo folder + bytes) and `remove(modelID:)` for the retired-weights
//  cleanup (#222); same HubApi path math, so listing and deleting cannot
//  drift from downloading.

import Foundation
import Hub

public struct LocalModelInventory: Sendable {
    private let hub: HubApi

    /// - Parameter downloadBase: the LLM download root; defaults to the same
    ///   Application Support base `HubApiDownloader.llmDefault` uses (Caches
    ///   until 2026-07-31 — see ModelStoreLocation; pure resolution, the
    ///   migration is the app's explicit prepareOnce()).
    public init(downloadBase: URL? = nil) {
        let base = downloadBase ?? ModelStoreLocation.llmBase()
        hub = HubApi(downloadBase: base)
    }

    /// Whether the model's weights are present on disk. `false` for an absent or
    /// metadata-only (interrupted) download.
    public func isInstalled(modelID: String) -> Bool {
        let dir = hub.localRepoLocation(Hub.Repo(id: modelID))
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return false }
        return entries.contains { $0.pathExtension == "safetensors" }
    }

    /// Every `models/<org>/<repo>` folder under the download base with its size
    /// on disk (all files, recursively). Dot-folders (`.m1k3-receipts`) are not
    /// repos and are skipped. Feeds `RetiredWeightsPolicy` — listing only.
    public func installedWeights() -> [InstalledWeights] {
        let fm = FileManager.default
        let models = hub.localRepoLocation(Hub.Repo(id: "org/repo"))
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let orgs = try? fm.contentsOfDirectory(at: models, includingPropertiesForKeys: nil) else { return [] }
        var out: [InstalledWeights] = []
        for org in orgs where !org.lastPathComponent.hasPrefix(".") {
            guard let repos = try? fm.contentsOfDirectory(at: org, includingPropertiesForKeys: nil) else { continue }
            for repo in repos where !repo.lastPathComponent.hasPrefix(".") {
                guard (try? repo.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                out.append(InstalledWeights(
                    repoID: "\(org.lastPathComponent)/\(repo.lastPathComponent)", bytes: Self.directorySize(repo)
                ))
            }
        }
        return out
    }

    /// Delete one repo folder. A folder that is already gone is not an error —
    /// the user's intent (not on disk) is met either way.
    public func remove(modelID: String) throws {
        let dir = hub.localRepoLocation(Hub.Repo(id: modelID))
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        try FileManager.default.removeItem(at: dir)
    }

    private static func directorySize(_ dir: URL) -> Int64 {
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
