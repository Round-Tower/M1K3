//
//  MLXEmbeddingServiceTests.swift
//  M1K3MLXTests
//
//  Two tiers. The fast tier asserts the pure surface (protocol conformance,
//  declared dimension) with no model load — runs in CI / the normal loop. The
//  integration tier actually downloads + runs the model and is gated behind the
//  M1K3_MLX_INTEGRATION env var, because it needs network + Metal + ~minutes on
//  first run. Same split the prior knowledge-server uses to keep its fast loop fast.
//
//  KNOWN LIMIT (2026-06-06): the integration tier does NOT run under CLI
//  `swift test` — MLX aborts with "Failed to load the default metallib (library
//  not found)" because mlx-swift resolves its Metal kernels relative to the
//  running binary, and the xctest runner isn't an .app bundle. Real on-device
//  execution is verified by launching M1K3.app (which bundles the metallib) or
//  via an xctest host app. The gate stays env-var'd so normal runs are clean;
//  flipping it from the CLI will abort, by design of MLX, not a code fault.
//
//  Run integration (needs app-bundle context): M1K3_MLX_INTEGRATION=1
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.8, Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-10-10 (one embedder: EmbeddingGemma 2) — the default is EmbeddingGemma 2; Qwen stays constructible with its old fingerprint.

import Foundation
import M1K3Knowledge
@testable import M1K3MLX
import MLXEmbedders
import Testing

struct MLXEmbeddingServiceTests {
    @Test("conforms to EmbeddingService and reports its dimension")
    func dimensionAndConformance() {
        let service: any EmbeddingService = MLXEmbeddingService()
        #expect(service.dimension == 512) // EmbeddingGemma 2 768, MRL-truncated
    }

    @Test("the default is EmbeddingGemma 2; its fingerprint encodes the model, the width and the prompt version")
    func fingerprintEncodesModelAndDimension() {
        // The fingerprint drives the store's auto re-index. Encoding the
        // truncated width means a future MRL dim change (512→256) re-embeds
        // even though the model id is unchanged — distinct vector spaces.
        let service = MLXEmbeddingService()
        #expect(service.prompting == .embeddingGemma2)
        let fp = service.fingerprint
        #expect(fp.hasPrefix(EmbedderFloors.embeddingGemma2IdentityPrefix), "the floors follow the fingerprint")
        #expect(fp.contains("d512"))
        #expect(fp.contains(MLXEmbeddingService.kernelTag))
        #expect(fp.hasSuffix(MLXEmbeddingService.gemmaPromptVersion))
        // And it must differ from the Qwen marker so existing stores migrate once.
        #expect(fp != "mlx/mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ/d512/\(MLXEmbeddingService.kernelTag)")
    }

    @Test("Qwen3-Embedding stays constructible for the A/B harness, with its old fingerprint")
    func qwenRemainsConstructible() {
        let qwen = MLXEmbeddingService(configuration: EmbedderRegistry.qwen3_embedding)
        #expect(qwen.prompting == .qwen3Instruct)
        let kernel = MLXEmbeddingService.kernelTag
        #expect(qwen.fingerprint == "mlx/mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ/d512/\(kernel)")
    }

    @Test("an explicitly-constructed bge_small still carries its own 384-dim identity")
    func legacyEmbedderRemainsConstructible() {
        // The A/B separation harness needs to stand the OLD embedder up beside
        // the new one — the init params must survive the default change.
        let bge = MLXEmbeddingService(configuration: EmbedderRegistry.bge_small, dimension: 384)
        #expect(bge.dimension == 384)
        #expect(bge.fingerprint.contains("bge-small-en-v1.5"))
        #expect(bge.fingerprint.contains("d384"))
    }

    @Test("kernelTag matches the mlx-swift minor actually pinned in Package.resolved")
    func kernelTagMatchesPinnedVersion() throws {
        // kernelTag is a hand-bumped contract: when an mlx-swift bump changes
        // the embedding kernels, stored vectors must re-index (EmbedderReindex-
        // Policy). Reading the REAL pin makes forgetting the bump a test
        // failure instead of a silently mixed vector space.
        let resolved = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // M1K3MLXTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // macos/
            .appendingPathComponent("Package.resolved")
        let data = try Data(contentsOf: resolved)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let pins = try #require(json?["pins"] as? [[String: Any]])
        let mlxSwift = try #require(pins.first { $0["identity"] as? String == "mlx-swift" })
        let state = try #require(mlxSwift["state"] as? [String: Any])
        let version = try #require(state["version"] as? String)
        let minor = version.split(separator: ".").prefix(2).joined(separator: ".")
        #expect(MLXEmbeddingService.kernelTag == "mlx-swift-\(minor)",
                "mlx-swift moved to \(version) — bump kernelTag so stores re-index")
    }

    @Test(
        "INTEGRATION: embeds text into a unit-length vector of the right size",
        .enabled(if: ProcessInfo.processInfo.environment["M1K3_MLX_INTEGRATION"] == "1")
    )
    func embedsRealText() async throws {
        let service = MLXEmbeddingService()
        #expect(await service.isAvailable())

        let vector = try await service.embed("The hydraulic seal failed under load.")
        #expect(vector.count == service.dimension)

        // bge_small normalises — magnitude should be ~1.
        let magnitude = (vector.reduce(0) { $0 + $1 * $1 }).squareRoot()
        #expect(abs(magnitude - 1.0) < 0.01)
    }
}
