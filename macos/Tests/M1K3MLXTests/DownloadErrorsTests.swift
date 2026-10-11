//
//  DownloadErrorsTests.swift
//  M1K3MLXTests
//
//  #557: swift-transformers wraps URL errors as Hub.HubClientError.downloadError(String)
//  / .networkError(URLError), which neither the retry predicate nor the fallback check
//  recognised, so a timeout got no retry and no verified-local fallback. Also the three
//  weight-integrity errors as LocalizedError, and the manifest sizes behind the
//  downloads catalogue.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.8. Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-11 (pre-push review fold) — C1 cancelled-not-offline and C2 type-based disk-full / error matrix. Confidence 0.85.

import Foundation
import Hub
import M1K3Inference
@testable import M1K3MLX
import Testing

struct DownloadErrorsTests {
    @Test("a wrapped download error and a transient network error are retried")
    func hubErrorsRetry() {
        #expect(RetryPolicy.isTransientNetworkError(Hub.HubClientError.downloadError("The request timed out.")))
        #expect(RetryPolicy.isTransientNetworkError(Hub.HubClientError.networkError(URLError(.timedOut))))
        #expect(RetryPolicy.isTransientNetworkError(Hub.HubClientError.networkError(URLError(.notConnectedToInternet))))
    }

    @Test("a wrapped timeout is fallback-worthy, so a verified local copy still loads")
    func hubErrorsFallBack() {
        #expect(HubApiDownloader.isFallbackWorthy(Hub.HubClientError.downloadError("The request timed out.")))
        #expect(HubApiDownloader.isFallbackWorthy(Hub.HubClientError.networkError(URLError(.timedOut))))
    }

    @Test("a non-transient URL error and a wrapped full disk are neither retried nor fallback-worthy")
    func hubErrorsThatAreNotTransient() {
        #expect(!RetryPolicy.isTransientNetworkError(Hub.HubClientError.networkError(URLError(.badURL))))
        let full = Hub.HubClientError.downloadError("The file couldn’t be saved because there is no space left on the device.")
        #expect(!RetryPolicy.isTransientNetworkError(full))
        #expect(DownloadFailureCopy.kind(of: full) == .diskFull)
        #expect(!RetryPolicy.isTransientNetworkError(Hub.HubClientError.parse))
    }

    /// Runs `body` inside a Task that has been cancelled, so `Task.isCancelled` is true.
    private func whileCancelled<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        let task = Task<T, Never> {
            while !Task.isCancelled {
                await Task.yield()
            }
            return body()
        }
        task.cancel()
        return await task.value
    }

    @Test("C1: a wrapped download error after a deliberate cancel reads as cancelled, never offline")
    func wrappedCancelIsCancelled() async {
        let wrapped = Hub.HubClientError.downloadError("The operation couldn’t be completed.")
        let (kind, retried, fallback) = await whileCancelled {
            (DownloadFailureCopy.kind(of: wrapped), RetryPolicy.isTransientNetworkError(wrapped),
             HubApiDownloader.isFallbackWorthy(wrapped))
        }
        #expect(kind == .cancelled)
        #expect(!retried)
        #expect(!fallback, "a cancel must not hand back a partial local folder as success")
        // Outside a cancelled task the same string stays a network blip.
        #expect(DownloadFailureCopy.kind(of: wrapped) == .offline)
        // A weak extra: the system's own cancelled wording.
        #expect(DownloadFailureCopy.kind(of: Hub.HubClientError.downloadError("The operation was cancelled.")) == .cancelled)
        #expect(!DownloadFailureCopy.message(for: Hub.HubClientError.downloadError("cancelled"))
            .localizedCaseInsensitiveContains("reach"))
    }

    @Test("C1: a cancelled URLError is neither retried nor fallback-worthy")
    func cancelledNetworkError() {
        for error: Error in [Hub.HubClientError.networkError(URLError(.cancelled)), URLError(.cancelled), CancellationError()] {
            #expect(DownloadFailureCopy.kind(of: error) == .cancelled, "\(error)")
            #expect(!RetryPolicy.isTransientNetworkError(error), "\(error)")
            #expect(!HubApiDownloader.isFallbackWorthy(error), "\(error)")
        }
    }

    @Test("C2: a real full disk is classified by type, Cocoa and POSIX, not by wording")
    func diskFullByType() {
        let cocoa = Hub.HubClientError.fileSystemError(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError))
        let posix = Hub.HubClientError.fileSystemError(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)))
        let nested = Hub.HubClientError.fileSystemError(NSError(
            domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))]
        ))
        for error in [cocoa, posix, nested] {
            #expect(DownloadFailureCopy.kind(of: error) == .diskFull, "\(error)")
            #expect(!RetryPolicy.isTransientNetworkError(error), "\(error)")
            #expect(!HubApiDownloader.isFallbackWorthy(error), "\(error)")
        }
        // A file-system error that is not a full disk stays unclassified.
        let other = Hub.HubClientError.fileSystemError(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError))
        #expect(DownloadFailureCopy.kind(of: other) == .unknown)
    }

    @Test("C2: auth, missing-file and HTTP errors are classified and not retried; only 5xx falls back")
    func hubErrorMatrix() {
        let notRetried: [Hub.HubClientError] = [
            .authorizationRequired, .fileNotFound("x"), .httpStatusCode(404), .httpStatusCode(500),
        ]
        for error in notRetried {
            #expect(!RetryPolicy.isTransientNetworkError(error), "\(error)")
            #expect(DownloadFailureCopy.kind(of: error) == .unknown, "\(error)")
        }
        #expect(!HubApiDownloader.isFallbackWorthy(Hub.HubClientError.authorizationRequired))
        #expect(!HubApiDownloader.isFallbackWorthy(Hub.HubClientError.fileNotFound("x")))
        #expect(!HubApiDownloader.isFallbackWorthy(Hub.HubClientError.httpStatusCode(404)))
        #expect(HubApiDownloader.isFallbackWorthy(Hub.HubClientError.httpStatusCode(500)))
    }

    @Test("integrity errors are not retried, not fallback-worthy, and classify as integrity")
    func integrityNotTransient() {
        let errors: [Error] = [
            WeightTamperError(repoID: "a/b", files: ["model.safetensors"]),
            WeightsStaleError(repoID: "a/b", localRevision: "aaaaaaaaaaaaaaaa", pinnedRevision: "bbbbbbbbbbbbbbbb"),
            WeightUnverifiableError(repoID: "a/b", files: ["model.safetensors"]),
        ]
        for error in errors {
            #expect(!RetryPolicy.isTransientNetworkError(error))
            #expect(!HubApiDownloader.isFallbackWorthy(error))
            guard case let .integrity(message) = DownloadFailureCopy.kind(of: error) else {
                Issue.record("not integrity: \(error)")
                continue
            }
            #expect(!message.isEmpty && !message.contains("sha256"))
        }
    }

    @Test("the weight errors speak through LocalizedError with their existing text")
    func localizedText() {
        let tamper = WeightTamperError(repoID: "a/b", files: ["x", "y"])
        #expect(tamper.localizedDescription == tamper.description)
        #expect(tamper.localizedDescription.contains("Refusing to load a/b"))
        let stale = WeightsStaleError(repoID: "a/b", localRevision: "aaaaaaaaaaaaaaaa", pinnedRevision: "bbbbbbbbbbbbbbbb")
        #expect(stale.localizedDescription == stale.description)
        #expect(stale.localizedDescription.contains("earlier release"))
        let unverifiable = WeightUnverifiableError(repoID: "a/b", files: ["x"])
        #expect(unverifiable.localizedDescription == unverifiable.description)
        #expect(unverifiable.localizedDescription.contains("Could not verify a/b"))
        for text in [tamper.localizedDescription, stale.localizedDescription, unverifiable.localizedDescription] {
            #expect(!text.contains("couldn’t be completed"))
        }
    }

    @Test("manifest totals sit close to each tier's advertised download size")
    func manifestSizesMatchTierEstimates() throws {
        for tier in [BrainTier.pocket, .lil, .big] {
            let id = try #require(tier.mlxModelID)
            let bytes = try #require(PinnedWeights.totalBytes(forRepo: id), "\(id) is not pinned")
            let advertised = Double(tier.approxDownloadMB ?? 0) * 1_000_000
            #expect(abs(Double(bytes) - advertised) / advertised < 0.10, "\(tier): \(bytes) vs \(advertised)")
        }
        #expect(PinnedWeights.totalBytes(forRepo: "nobody/unpinned") == nil)
    }

    @Test("DownloadSizes.manifest carries exact brain and embedder sizes and flags the estimates")
    func catalogueSizes() throws {
        let sizes = DownloadSizes.manifest(sharperEarsBytes: 480_000_000, voiceBytes: 191_000_000)
        let lil = try #require(BrainTier.lil.mlxModelID)
        #expect(sizes.bytes[.lil] == PinnedWeights.totalBytes(forRepo: lil))
        #expect(sizes.bytes[.semanticMemory] == PinnedWeights.totalBytes(forRepo: "mlx-community/embeddinggemma-2-8bit"))
        #expect(!sizes.approximate.contains(.lil))
        #expect(sizes.approximate.isSuperset(of: [.sharperEars, .voice]))
    }

    @Test("the embedder inventory is rooted at Documents/huggingface, apart from the brain store")
    func embedderInventoryRoot() {
        #expect(LocalModelInventory.embedderBase()?.path.hasSuffix("Documents/huggingface") == true)
    }
}
