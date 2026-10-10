//
//  EmbeddingGemma2Tests.swift
//  M1K3MLXTests
//
//  The pure half of the EmbeddingGemma 2 port (GEMMA_1_1_PLAN Stream C, slice 2):
//  the configuration decoded from the real 8-bit checkpoint's config.json, the
//  parameter paths the module declares against the checkpoint's weight index,
//  the text-core key filter, and the model-card prompts. The numeric half runs
//  inside the app (EmbeddingGemma2RefStage, M1K3_SELFTEST_EG2REF=1) against
//  Fixtures/embeddinggemma2-reference.json — the metallib wall keeps it out of
//  `swift test`.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-10, Confidence 0.85, Prior: none
//  (new file). Review: Kev + claude-fable-5.1, 2026-10-10 (#545 fold) — `capped` edge cases.
//  The key-pattern fixture is the checkpoint's own index; the
//  module's own `@ModuleInfo` keys cannot be read without MLX, so the list in
//  `weightKeys(for:)` pins the naming convention and the loader's
//  `verify: .all` plus the in-app stage are the runtime guard.

import Foundation
import M1K3Knowledge
@testable import M1K3MLX
import MLXLMCommon
import Testing

struct EmbeddingGemma2Tests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func configuration() throws -> EmbeddingGemma2Configuration {
        try JSONDecoder().decode(EmbeddingGemma2Configuration.self, from: fixture("embeddinggemma2-config"))
    }

    @Test("the checkpoint's config.json decodes to the 270M text core, encoders ignored")
    func decodesTextCore() throws {
        let config = try configuration()
        #expect(config.hiddenSize == 512)
        #expect(config.hiddenLayers == 24)
        #expect(config.attentionHeads == 4)
        #expect(config.intermediateSize == 2048)
        #expect(config.perLayerInputSize == 512)
        #expect(config.embeddingDim == 768)
        #expect(config.vocabularySize == 262_144)
        #expect(config.slidingWindow == 512)
        #expect(config.rmsNormEps == 1e-6)
        #expect(config.padTokenID == 0)
    }

    @Test("every sixth layer is global with one 512-wide KV head on the 1M rope; the rest slide at 2×256 on 10k")
    func layerLayout() throws {
        let layers = try configuration().layers
        #expect(layers.count == 24)
        for (index, layer) in layers.enumerated() {
            let global = (index + 1) % 6 == 0
            #expect(layer.isGlobal == global, "layer \(index)")
            #expect(layer.headDim == (global ? 512 : 256), "layer \(index)")
            #expect(layer.kvHeads == (global ? 1 : 2), "layer \(index)")
            #expect(layer.ropeBase == (global ? 1_000_000 : 10000), "layer \(index)")
        }
    }

    @Test("a text-only checkpoint (fields at the top level, HF's bare per-layer keys) decodes the same way")
    func topLevelTextConfig() throws {
        let root = try JSONSerialization.jsonObject(with: fixture("embeddinggemma2-config")) as? [String: Any]
        let text = try #require(root?["text_config"] as? [String: Any])
        var flat = text
        flat["model_type"] = "embedding_gemma2_text"
        flat["quantization"] = ["group_size": 64, "bits": 8]
        // transformers serialises the integer layer index ("5"); mlx-vlm zero-pads ("05").
        flat["per_layer_config"] = ["5": ["head_dim": 512, "num_key_value_heads": 1]]
        let data = try JSONSerialization.data(withJSONObject: flat)
        let config = try JSONDecoder().decode(EmbeddingGemma2Configuration.self, from: data)
        #expect(config.hiddenLayers == 24)
        #expect(config.layers[5].isGlobal)
        #expect(config.layers[5].headDim == 512)
        #expect(config.layers[5].kvHeads == 1)
        #expect(config.layers[11].headDim == 256, "no override given for layer 11")
    }

    @Test("a per_layer_config key that is not a layer index is refused")
    func refusesBadPerLayerKey() throws {
        var root = try #require(JSONSerialization.jsonObject(with: fixture("embeddinggemma2-config")) as? [String: Any])
        var text = try #require(root["text_config"] as? [String: Any])
        text["per_layer_config"] = ["global": ["head_dim": 512]]
        root["text_config"] = text
        let data = try JSONSerialization.data(withJSONObject: root)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EmbeddingGemma2Configuration.self, from: data)
        }
    }

    @Test("an over-long input is cut at the context window with <eos> kept")
    func contextCap() {
        let ids = [2] + Array(100 ..< 100 + 9000) + [1]
        let capped = EmbeddingGemma2Embedder.capped(ids, to: EmbeddingGemma2TextModel.contextLength)
        #expect(capped.count == 8192)
        #expect(capped.first == 2)
        #expect(capped.last == 1)
        #expect(capped[1] == 100)
        #expect(EmbeddingGemma2Embedder.capped([2, 5, 1], to: 8192) == [2, 5, 1])
        #expect(EmbeddingGemma2Embedder.capped([], to: 8192) == [])
        #expect(EmbeddingGemma2Embedder.capped([2, 5, 1], to: 1) == [1], "a one-token limit keeps <eos>")
        #expect(EmbeddingGemma2Embedder.capped([2, 5, 1], to: 2) == [2, 1])
    }

    @Test("a foreign model_type is refused rather than decoded as Gemma")
    func refusesOtherModelTypes() throws {
        var root = try #require(JSONSerialization.jsonObject(with: fixture("embeddinggemma2-config")) as? [String: Any])
        root["model_type"] = "gemma3"
        let data = try JSONSerialization.data(withJSONObject: root)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EmbeddingGemma2Configuration.self, from: data)
        }
    }

    @Test("the module's parameter paths are exactly the checkpoint's language_model.* keys")
    func parameterPathsMatchCheckpoint() throws {
        struct Keys: Decodable {
            struct Pattern: Decodable {
                let key: String
                let count: Int
            }

            let textKeys: Int
            let textPatterns: [Pattern]
        }
        let keys = try JSONDecoder().decode(Keys.self, from: fixture("embeddinggemma2-weight-keys"))
        let expected = try EmbeddingGemma2TextModel.weightKeys(for: configuration())
        #expect(expected.count == keys.textKeys)
        var folded: [String: Int] = [:]
        for key in expected {
            let pattern = key.replacing(#/\.layers\.\d+\./#, with: ".layers.N.")
            folded[pattern, default: 0] += 1
        }
        let fixturePatterns = Dictionary(uniqueKeysWithValues: keys.textPatterns.map { ($0.key, $0.count) })
        #expect(folded == fixturePatterns)
    }

    @Test("sanitize keeps the text core, drops the encoders, and prefixes a text-only checkpoint's keys")
    func sanitizeFilter() {
        #expect(EmbeddingGemma2TextModel.textCoreKey("language_model.layers.3.mlp.up_proj.weight")
            == "language_model.layers.3.mlp.up_proj.weight")
        #expect(EmbeddingGemma2TextModel.textCoreKey("model.language_model.norm.weight")
            == "language_model.norm.weight")
        #expect(EmbeddingGemma2TextModel.textCoreKey("layers.0.layer_scalar") == "language_model.layers.0.layer_scalar")
        #expect(EmbeddingGemma2TextModel.textCoreKey("embed_tokens.weight") == "language_model.embed_tokens.weight")
        #expect(EmbeddingGemma2TextModel.textCoreKey("vision_tower.encoder.layers.0.input_layernorm.weight") == nil)
        #expect(EmbeddingGemma2TextModel.textCoreKey("embed_vision.embedding_projection.weight") == nil)
        #expect(EmbeddingGemma2TextModel.textCoreKey("audio_tower.layers.0.norm_out.weight") == nil)
        #expect(EmbeddingGemma2TextModel.textCoreKey("embed_audio.embedding_projection.scales") == nil)
    }

    @Test("the service composes the model card's prompts for EmbeddingGemma 2 and leaves Qwen alone")
    func servicePrompting() {
        let gemma = MLXEmbeddingService(configuration: MLXEmbeddingService.embeddingGemma2)
        #expect(gemma.prompting == .embeddingGemma2)
        #expect(gemma.dimension == 512)
        let kernel = MLXEmbeddingService.kernelTag
        let salt = MLXEmbeddingService.gemmaPromptVersion
        #expect(gemma.fingerprint == "mlx/mlx-community/embeddinggemma-2-8bit/d512/\(kernel)/\(salt)")
        // The prompt strings and the version are one unit: editing either prefix means bumping the version.
        #expect(MLXEmbeddingService.gemmaPromptVersion == "prompt-v1")
        #expect(EmbeddingText.gemmaDocumentPrefix == "title: none | text: ", "edit → bump gemmaPromptVersion")
        #expect(EmbeddingText.gemmaQueryPrefix == "task: search result | query: ", "edit → bump gemmaPromptVersion")
        #expect(gemma.composeDocument("Pro is €8 a month.") == "title: none | text: Pro is €8 a month.")
        #expect(gemma.composeQuery("what does Pro cost?") == "task: search result | query: what does Pro cost?")

        let qwen = MLXEmbeddingService()
        #expect(qwen.prompting == .qwen3Instruct)
        #expect(qwen.fingerprint == "mlx/mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ/d512/\(kernel)", "unchanged")

        let local = MLXEmbeddingService(
            configuration: ModelConfiguration(directory: URL(fileURLWithPath: "/tmp/eg2")), prompting: .embeddingGemma2
        )
        #expect(local.prompting == .embeddingGemma2, "a directory load is routed by the explicit parameter")
        #expect(qwen.composeDocument("Pro is €8 a month.") == "Pro is €8 a month.")
        #expect(qwen.composeQuery("what does Pro cost?") == EmbeddingText.forQuery("what does Pro cost?"))
    }
}
