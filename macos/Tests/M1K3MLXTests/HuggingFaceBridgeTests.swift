//
//  HuggingFaceBridgeTests.swift
//  M1K3MLXTests
//
//  Pins the bridge's cache-layout contract: the 3.x Downloader must resolve
//  models to the SAME directories the 2.x line used, or every user re-downloads
//  gigabytes of weights on upgrade. The network download + tokenizer load are
//  verify-by-launch (documented in HuggingFaceBridge.swift); the layout and the
//  protocol conformances are the regression surface here.
//
//  Signed: Kev + claude-fable-5, 2026-06-10, Confidence 0.8, Prior: Unknown
//

import Foundation
import Hub
@testable import M1K3MLX
import MLXLMCommon
import Testing

struct HuggingFaceBridgeTests {
    @Test("LLM downloader resolves to the Application Support layout — purge-safe since 2026-07-31")
    func llmStoreLayout() {
        let location = HubApiDownloader.llmDefault.hub
            .localRepoLocation(Hub.Repo(id: "mlx-community/gemma-3n-E4B-it-lm-4bit"))
        // The old "no re-download on upgrade" concern this test used to pin
        // against the Caches layout is now carried by ModelStoreLocation's
        // migration (fixture-pinned in ModelStoreLocationTests); what must
        // never regress HERE is weights landing back in purge-eligible Caches.
        #expect(location.path.contains("Application Support/models/mlx-community/gemma-3n-E4B-it-lm-4bit"))
        #expect(!location.path.contains("Caches/"))
    }

    @Test("embedder downloader resolves to the 2.x Documents/huggingface layout")
    func embedderCacheLayout() {
        let location = HubApiDownloader.embedderDefault.hub
            .localRepoLocation(Hub.Repo(id: "BAAI/bge-small-en-v1.5"))
        // 2.x HubApi() default: <documents>/huggingface/models/<org>/<name>
        #expect(location.path.contains("huggingface/models/BAAI/bge-small-en-v1.5"))
    }

    @Test("bridge types satisfy the 3.x loading seams")
    func conformances() {
        let downloader: any MLXLMCommon.Downloader = HubApiDownloader.llmDefault
        let loader: any MLXLMCommon.TokenizerLoader = TransformersTokenizerLoader()
        #expect(downloader is HubApiDownloader)
        #expect(loader is TransformersTokenizerLoader)
    }

    // MARK: - isFallbackWorthy (#72 item 2: broaden the offline-fallback catch)

    /// True offline (`NSURLErrorNotConnectedToInternet`) must keep falling
    /// back — this is the ORIGINAL narrow check, preserved.
    @Test("true offline is fallback-worthy")
    func trueOfflineIsFallbackWorthy() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(HubApiDownloader.isFallbackWorthy(error))
    }

    /// The gap #72 closes: connected-but-unhealthy looked nothing like
    /// offline to the old check, so a timeout or DNS blip fell through to the
    /// raw-failure rethrow instead of the verified local copy.
    @Test("transient network errors (timeout, DNS failure) are fallback-worthy")
    func transientNetworkErrorsAreFallbackWorthy() {
        #expect(HubApiDownloader.isFallbackWorthy(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
        #expect(HubApiDownloader.isFallbackWorthy(NSError(domain: NSURLErrorDomain, code: NSURLErrorDNSLookupFailed)))
        #expect(HubApiDownloader.isFallbackWorthy(NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)))
    }

    /// A Hub 5xx isn't an NSURLError at all — it's the Hub's OWN error type —
    /// so the old NSURLErrorDomain-only check could never have matched it.
    @Test("Hub 5xx responses are fallback-worthy")
    func hub5xxIsFallbackWorthy() {
        #expect(HubApiDownloader.isFallbackWorthy(Hub.HubClientError.httpStatusCode(500)))
        #expect(HubApiDownloader.isFallbackWorthy(Hub.HubClientError.httpStatusCode(503)))
        #expect(HubApiDownloader.isFallbackWorthy(Hub.HubClientError.httpStatusCode(599)))
    }

    /// A Hub 4xx is a CLIENT error (bad request, not found) — retrying or
    /// falling back to a stale cache hides a real problem rather than a
    /// transient one, so this must stay OUT of the fallback-worthy set.
    @Test("Hub 4xx responses are NOT fallback-worthy")
    func hub4xxIsNotFallbackWorthy() {
        #expect(!HubApiDownloader.isFallbackWorthy(Hub.HubClientError.httpStatusCode(404)))
        #expect(!HubApiDownloader.isFallbackWorthy(Hub.HubClientError.httpStatusCode(429)))
    }

    /// `authorizationRequired` already has its OWN dedicated catch clause in
    /// `download` (repo-doesn't-exist) — it must not also match here, or the
    /// two branches would race for the same error.
    @Test("Hub authorizationRequired is NOT fallback-worthy — it has its own catch clause")
    func hubAuthRequiredIsNotFallbackWorthy() {
        #expect(!HubApiDownloader.isFallbackWorthy(Hub.HubClientError.authorizationRequired))
    }

    /// An unrelated error domain (a decode failure, say) must not be swept
    /// into the fallback path either.
    @Test("an unrelated error is NOT fallback-worthy")
    func unrelatedErrorIsNotFallbackWorthy() {
        #expect(!HubApiDownloader.isFallbackWorthy(NSError(domain: "some.other.domain", code: 1)))
    }

    // MARK: - shouldSkipNetworkFetch (#72 item 1: the useLatest pre-network decision)

    /// A temp directory standing in for a model cache — same shape as
    /// `WeightIntegrityScanTests.Sandbox`, duplicated locally rather than
    /// shared across test targets (test-only, and each file already owns its
    /// fixture helpers independently in this suite).
    private struct FixtureDirectory: ~Copyable {
        let url: URL
        init() throws {
            url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("hf-bridge-fixture-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        func write(_ contents: String, to name: String) throws {
            try Data(contents.utf8).write(to: url.appendingPathComponent(name))
        }

        deinit { try? FileManager.default.removeItem(at: url) }
    }

    private static func fixturePin(contents: [String: String]) -> WeightIntegrity.Pin {
        var files: [String: WeightIntegrity.PinnedFile] = [:]
        for (name, body) in contents {
            let bytes = Data(body.utf8)
            files[name] = .init(size: bytes.count, sha256: WeightIntegrityScan.sha256Hex(of: bytes))
        }
        return .init(revision: "abc", files: files)
    }

    @Test("useLatest=false with a fully verified local copy skips the network")
    func skipsNetworkWhenVerifiedAndUseLatestFalse() throws {
        let fixture = try FixtureDirectory()
        try fixture.write("weights", to: "model.safetensors")
        let pin = Self.fixturePin(contents: ["model.safetensors": "weights"])

        #expect(HubApiDownloader.shouldSkipNetworkFetch(
            useLatest: false, directory: fixture.url, pin: pin, repoID: "org/repo"
        ))
    }

    @Test("useLatest=true never skips the network, even when the local copy verifies")
    func neverSkipsWhenUseLatestTrue() throws {
        let fixture = try FixtureDirectory()
        try fixture.write("weights", to: "model.safetensors")
        let pin = Self.fixturePin(contents: ["model.safetensors": "weights"])

        #expect(!HubApiDownloader.shouldSkipNetworkFetch(
            useLatest: true, directory: fixture.url, pin: pin, repoID: "org/repo"
        ))
    }

    @Test("an unpinned repo never skips the network — no completeness oracle to trust")
    func neverSkipsWhenUnpinned() throws {
        let fixture = try FixtureDirectory()
        try fixture.write("anything", to: "model.safetensors")

        #expect(!HubApiDownloader.shouldSkipNetworkFetch(
            useLatest: false, directory: fixture.url, pin: nil, repoID: "org/unpinned"
        ))
    }

    @Test("a partial (in-flight) download never skips the network")
    func neverSkipsWhenIncomplete() throws {
        let fixture = try FixtureDirectory()
        try fixture.write("weights", to: "model.safetensors")
        // config.json never arrived.
        let pin = Self.fixturePin(contents: ["model.safetensors": "weights", "config.json": "{}"])

        #expect(!HubApiDownloader.shouldSkipNetworkFetch(
            useLatest: false, directory: fixture.url, pin: pin, repoID: "org/repo"
        ))
    }
}
