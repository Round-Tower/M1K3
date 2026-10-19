//
//  BrainWeightsFetcher.swift
//  M1K3MLX
//
//  Download a brain's weights WITHOUT touching the live provider — the seam
//  behind the invitation-first background upgrade ("I'll grab Lil while we
//  keep talking"). `selectBrain`/`preloadGemma` cannot be the download vehicle:
//  both repoint the active provider immediately, and `modelLoad` drives the
//  readiness gate, so publishing this download there would hide a working chat
//  behind a bar that's supposed to be invisible.
//
//  Pure disk fetch: `HubApiDownloader.download` is a hub.snapshot with
//  byte-accurate progress — zero Metal, zero RAM while Mini serves. The swap
//  later pays a short from-disk `loadContainer` through the ordinary
//  `selectBrain` path. Patterns mirror upstream `modelDownloadPatterns`
//  exactly ("*.safetensors" + "*.json" + "*.jinja", mlx-swift-lm 3.32.3,
//  ModelFactory.swift:7-8) so detection, fetch, and load can never drift.
//
//  Cancellation: hub.snapshot rides URLSession — cancelling the wrapping Task
//  aborts cleanly and the partial snapshot resumes on the next attempt (either
//  a retry here or `loadContainer`'s own downloader at swap/pick time).
//
//  ⚠️ The underlying downloader treats offline/auth-required as "fall back to
//  the local copy" and RETURNS rather than throwing — a caller staging weights
//  must verify `LocalModelInventory.isInstalled` after this returns instead of
//  trusting the return alone. The coordinator does exactly that.
//
//  Signed: Kev + claude-fable-5, 2026-07-03, Confidence 0.85 (thin wrapper over
//  the proven downloader; behaviour behind the metallib wall is verify-by-launch).
//  Prior: none (new file).
//  Review: Kev + claude-opus-5-5, 2026-10-19 — the pattern comments name the pinned 3.32.3; `weightPatterns` is now
//  also what `LocalModelInventory.installState` cuts a pin to (its declaration shape is read by test_pin_weights.py).

import Foundation

public struct BrainWeightsFetcher: Sendable {
    /// Upstream `modelDownloadPatterns` (mlx-swift-lm 3.32.3) — the exact set
    /// `loadContainer` would fetch, so a staged snapshot is complete for it.
    static let weightPatterns = ["*.safetensors", "*.json", "*.jinja"]

    public init() {}

    /// Snapshot the model's weights into the same cache `loadContainer` reads
    /// (`HubApiDownloader.llmDefault`), reporting 0…1 progress. Throws on real
    /// failures; see the header for the offline-fallback caveat.
    public func fetch(
        modelID: String,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        _ = try await HubApiDownloader.llmDefault.download(
            id: modelID,
            revision: nil,
            matching: Self.weightPatterns,
            useLatest: false
        ) { snapshotProgress in
            progress(snapshotProgress.fractionCompleted)
        }
    }
}
