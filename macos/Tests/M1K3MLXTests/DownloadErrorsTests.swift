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
