//
//  DownloadErrors.swift
//  M1K3MLX
//
//  The MLX-side half of the downloads manager's plumbing:
//
//   1. #557. swift-transformers wraps URL failures as `Hub.HubClientError.downloadError(String)`
//      / `.networkError(URLError)`. `RetryPolicy.isTransientNetworkError` only looked for
//      `NSURLErrorDomain` and `HuggingFaceBridge.isFallbackWorthy` leans on it, so a timeout got
//      no retry and no fallback to a verified local copy. M1K3Inference cannot import Hub, so
//      the types classify THEMSELVES here (`DownloadFailureClassifying`) and the retry predicate
//      honours that by type. One honest exception: `downloadError` carries only a string, so a
//      full disk is told apart from a network blip by matching the system's "no space left"
//      wording in that string, the one string-match in the path; everything else is by type.
//   2. The three weight-integrity refusals classify as `.integrity` with a short sentence for a
//      person (their `LocalizedError` text stays the long, evidence-minded one).
//   3. Pinned-manifest sizes (`PinnedWeights.totalBytes`, `DownloadSizes.manifest`) so the
//      catalogue shows exact bytes, and the embedder's inventory root (Documents/huggingface).
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.8 (classification and sums are pinned
//  by DownloadErrorsTests; a real Hub timeout retrying is verify-by-launch). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-11 (pre-push review fold) — C1: a wrapped download error
//  inside a cancelled task classifies as cancelled, not offline. Confidence 0.85.

import Foundation
import Hub
import M1K3Inference

// MARK: - Hub's wrapped errors (#557)

extension Hub.HubClientError: DownloadFailureClassifying {
    public var downloadFailureKind: DownloadFailureKind? {
        switch self {
        case let .downloadError(message):
            // swift-transformers stringifies the underlying error (`error.localizedDescription`),
            // so type information is gone: the system's out-of-space wording is the only tell.
            //
            // A deliberate Cancel also lands here: `HubApi.httpGet` rethrows `CancellationError`
            // / `URLError.cancelled` as `.downloadError(localizedDescription)`. The task's own
            // cancelled flag is the by-type signal; the wording is a weak extra.
            if Task.isCancelled { return .cancelled }
            let lowered = message.lowercased()
            if lowered.contains("cancel") { return .cancelled }
            if lowered.contains("no space left") || lowered.contains("out of space") { return .diskFull }
            return .offline
        case let .networkError(urlError):
            if urlError.code == .cancelled { return .cancelled }
            return RetryPolicy.isTransientNetworkError(urlError) ? .offline : nil
        case let .fileSystemError(underlying):
            let kind = DownloadFailureCopy.kind(of: underlying)
            return kind == .unknown ? nil : kind
        default:
            return nil
        }
    }
}

// MARK: - Integrity refusals

extension WeightTamperError: DownloadFailureClassifying {
    public var downloadFailureKind: DownloadFailureKind? {
        .integrity(message: String(localized: """
        I didn't use those files: they don't match what this version of M1K3 expects. \
        I left them untouched. Try the download again, and tell us if it keeps happening.
        """))
    }
}

extension WeightsStaleError: DownloadFailureClassifying {
    public var downloadFailureKind: DownloadFailureKind? {
        .integrity(message: String(localized: """
        Those files are from an earlier release of M1K3. Nothing is wrong with them; \
        connect and download again to update them.
        """))
    }
}

extension WeightUnverifiableError: DownloadFailureClassifying {
    public var downloadFailureKind: DownloadFailureKind? {
        .integrity(message: String(localized: """
        I couldn't read those files to check them, so I didn't use them. Try again; if it \
        keeps happening, remove the download and fetch it fresh.
        """))
    }
}

// MARK: - Manifest sizes

public extension PinnedWeights {
    /// Total bytes of everything pinned for `repoID`, or nil when the repo is unpinned.
    static func totalBytes(forRepo repoID: String) -> Int64? {
        pin(for: repoID).map { $0.files.values.reduce(Int64(0)) { $0 + Int64($1.size) } }
    }
}

public extension DownloadSizes {
    /// The catalogue's sizes: exact pinned bytes for the brains and the embedder, and the
    /// caller's figures for the two downloads this module cannot see (WhisperKit's variant,
    /// Kokoro's files), flagged approximate.
    static func manifest(sharperEarsBytes: Int64, voiceBytes: Int64) -> DownloadSizes {
        var bytes: [DownloadKind: Int64] = [.sharperEars: sharperEarsBytes, .voice: voiceBytes]
        for kind in DownloadKind.allCases {
            guard let id = kind.brainTier?.mlxModelID, let total = PinnedWeights.totalBytes(forRepo: id) else { continue }
            bytes[kind] = total
        }
        if let embedder = PinnedWeights.totalBytes(forRepo: embedderRepoID) {
            bytes[.semanticMemory] = embedder
        }
        return DownloadSizes(bytes: bytes, approximate: [.sharperEars, .voice])
    }

    /// The pinned embedder (`MLXEmbeddingService.embeddingGemma2`).
    static let embedderRepoID = "mlx-community/embeddinggemma-2-8bit"
}

// MARK: - The embedder's store

public extension LocalModelInventory {
    /// The embedder's download root: HubApi's default, `Documents/huggingface` (2.x layout,
    /// kept so existing caches work; see `HubApiDownloader.embedderDefault`). Apart from the
    /// brains' Application Support store, so it needs its own inventory.
    static func embedderBase() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("huggingface", isDirectory: true)
    }

    /// An inventory over the embedder's store. Returns nil only if Documents cannot be resolved.
    static func embedder() -> LocalModelInventory? {
        embedderBase().map { LocalModelInventory(downloadBase: $0) }
    }
}
