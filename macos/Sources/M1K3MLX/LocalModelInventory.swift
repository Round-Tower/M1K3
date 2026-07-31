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

import Foundation
import Hub

public struct LocalModelInventory: Sendable {
    private let hub: HubApi

    /// - Parameter downloadBase: the LLM download root; defaults to the same
    ///   prepared Application Support base `HubApiDownloader.llmDefault` uses
    ///   (Caches until 2026-07-31 — see ModelStoreLocation).
    public init(downloadBase: URL? = nil) {
        let base = downloadBase ?? ModelStoreLocation.preparedLLMBase()
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
}
