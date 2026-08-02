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
}
