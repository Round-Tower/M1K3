//
//  Spark25Tests.swift
//  M1K3MLXTests
//
//  Fast tier (no Metal, no weights): the PURE parts of the Spark-X2.5/2.6 port —
//  the config read off the real `Spark-X2.6-4B` config.json, the layer pattern,
//  the rotary widths, the refusals, the sanitize key map and the tool dialect.
//  The forward pass is verify-by-launch (the in-app chateval), as every MLX model is.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-21, Confidence 0.8, Prior: none (new file).
//

import Foundation
@testable import M1K3MLX
import MLXLLM
import MLXLMCommon
import Testing

struct Spark25ConfigurationTests {
    private func fixture() throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: "spark-x2.6-4b-config", withExtension: "json", subdirectory: "Fixtures"
        ))
        return try Data(contentsOf: url)
    }

    @Test("the real X2.6 config decodes: 36 layers, 9 full, 16 heads over 4 KV heads of 256")
    func decodesRealConfig() throws {
        let config = try JSONDecoder().decode(Spark25Configuration.self, from: fixture())
        #expect(config.modelType == "spark2_5")
        #expect(config.hiddenLayers == 36)
        #expect(config.layerTypes.count == 36)
        #expect(config.layerTypes.filter { $0 == Spark25Configuration.fullLayer }.count == 9)
        #expect(config.attentionHeads == 16)
        #expect(config.kvHeads == 4)
        #expect(config.headDim == 256)
        #expect(config.slidingWindow == 512)
        #expect(config.vocabularySize == 131_072)
        #expect(config.tieWordEmbeddings)
        #expect(config.firstSlidingLayer == 0)
        #expect(config.firstFullLayer == 3)
    }

    @Test("rotary width is 0.25 × head_dim on full layers, all of it on sliding layers; theta per kind")
    func rotaryWidths() throws {
        let config = try JSONDecoder().decode(Spark25Configuration.self, from: fixture())
        #expect(config.ropeDimensions(for: Spark25Configuration.fullLayer) == 64)
        #expect(config.ropeDimensions(for: Spark25Configuration.slidingLayer) == 256)
        #expect(config.ropeTheta(for: Spark25Configuration.fullLayer) == 5_000_000)
        #expect(config.ropeTheta(for: Spark25Configuration.slidingLayer) == 10000)
    }

    @Test("every fourth layer is full attention, the rest sliding")
    func layerPattern() throws {
        let config = try JSONDecoder().decode(Spark25Configuration.self, from: fixture())
        for i in 0 ..< config.hiddenLayers {
            #expect(config.isSliding(layer: i) == ((i + 1) % 4 != 0), "layer \(i)")
        }
        #expect(Spark25Configuration.defaultLayerTypes(count: 8) == [
            "sliding_attention", "sliding_attention", "sliding_attention", "full_attention",
            "sliding_attention", "sliding_attention", "sliding_attention", "full_attention",
        ])
    }

    @Test("a layer count that is not a multiple of four still follows the pattern from the top")
    func patternTail() {
        #expect(Spark25Configuration.defaultLayerTypes(count: 6) == [
            "sliding_attention", "sliding_attention", "sliding_attention", "full_attention",
            "sliding_attention", "sliding_attention",
        ])
    }

    @Test("a missing partial_rotary_factor means the whole head rotates; untied embeddings decode")
    func optionalFields() throws {
        var json = try #require(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        json["rope_parameters"] = [
            "sliding_attention": ["rope_theta": 10000],
            "full_attention": ["rope_theta": 5_000_000, "partial_rotary_factor": 0.25],
        ]
        json["tie_word_embeddings"] = false
        let config = try JSONDecoder().decode(
            Spark25Configuration.self, from: JSONSerialization.data(withJSONObject: json)
        )
        #expect(config.ropeDimensions(for: Spark25Configuration.slidingLayer) == 256)
        #expect(config.ropeDimensions(for: Spark25Configuration.fullLayer) == 64)
        #expect(!config.tieWordEmbeddings)
    }

    @Test("an odd or oversized rotary width is refused")
    func refusesBadRotaryWidth() throws {
        let base = try #require(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        for factor in [65.0 / 256.0, 1.5] { // 65 (odd) and 384 (over head_dim)
            var json = base
            json["rope_parameters"] = [
                "sliding_attention": ["rope_theta": 10000, "partial_rotary_factor": factor],
                "full_attention": ["rope_theta": 5_000_000, "partial_rotary_factor": 0.25],
            ]
            #expect(throws: Spark25Error.self, "factor \(factor)") {
                try JSONDecoder().decode(Spark25Configuration.self, from: JSONSerialization.data(withJSONObject: json))
            }
        }
    }

    @Test("newCache gives the sliding layers a rotating cache of the window and the full layers a plain one")
    func cacheShape() throws {
        let config = try JSONDecoder().decode(Spark25Configuration.self, from: fixture())
        let caches = try Spark25Model(config).newCache(parameters: nil)
        #expect(caches.count == 36)
        for (i, cache) in caches.enumerated() {
            if config.isSliding(layer: i) {
                #expect(cache is RotatingKVCache, "layer \(i)")
                #expect(cache.maxSize == 512, "layer \(i)")
            } else {
                #expect(cache is KVCacheSimple, "layer \(i)")
                #expect(cache.maxSize == nil, "layer \(i)")
            }
        }
    }

    @Test("a config without layer_types gets the 3:1 pattern")
    func defaultsLayerTypes() throws {
        var json = try #require(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        json.removeValue(forKey: "layer_types")
        let config = try JSONDecoder().decode(
            Spark25Configuration.self, from: JSONSerialization.data(withJSONObject: json)
        )
        #expect(config.layerTypes == Spark25Configuration.defaultLayerTypes(count: 36))
    }

    @Test("a config outside the one architecture this file implements is refused at decode")
    func refusesForeignConfigs() throws {
        let base = try #require(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
        func decode(_ edit: (inout [String: Any]) -> Void) throws -> Spark25Configuration {
            var json = base
            edit(&json)
            return try JSONDecoder().decode(
                Spark25Configuration.self, from: JSONSerialization.data(withJSONObject: json)
            )
        }
        #expect(throws: Spark25Error.self) { try decode { $0["hidden_act"] = "silu" } }
        #expect(throws: Spark25Error.self) { try decode { $0["gate_attn_act_mode"] = "swish" } }
        #expect(throws: Spark25Error.self) { try decode { $0["headwise_attn_output_gate"] = false } }
        #expect(throws: Spark25Error.self) { try decode { $0["layer_types"] = ["sliding_attention"] } }
        #expect(throws: Spark25Error.self) { try decode { $0["num_key_value_heads"] = 3 } }
        #expect(throws: Spark25Error.self) {
            try decode { $0["rope_parameters"] = ["sliding_attention": ["rope_theta": 10000]] }
        }
    }
}

struct Spark25SanitizeTests {
    @Test("embed_tokens is mapped back to the checkpoint's embedding key; tied lm_head and inv_freq are dropped")
    func keyMap() {
        #expect(Spark25Model.sanitizedKey("model.embed_tokens.weight", tiedWordEmbeddings: true)
            == "model.embedding.weight")
        #expect(Spark25Model.sanitizedKey("model.embed_tokens.scales", tiedWordEmbeddings: true)
            == "model.embedding.scales")
        #expect(Spark25Model.sanitizedKey("model.embedding.weight", tiedWordEmbeddings: true)
            == "model.embedding.weight")
        #expect(Spark25Model.sanitizedKey("lm_head.weight", tiedWordEmbeddings: true) == nil)
        #expect(Spark25Model.sanitizedKey("lm_head.weight", tiedWordEmbeddings: false) == "lm_head.weight")
        #expect(Spark25Model.sanitizedKey("model.layers.0.self_attn.rotary_emb.inv_freq", tiedWordEmbeddings: true)
            == nil)
        #expect(Spark25Model.sanitizedKey("model.layers.0.self_attn.g_proj.weight", tiedWordEmbeddings: true)
            == "model.layers.0.self_attn.g_proj.weight")
    }
}

struct Spark25DialectTests {
    @Test("spark2_5 speaks the GLM4 tool dialect, by model_type and by name")
    func glm4Dialect() {
        #expect(MLXBrainProvider.toolCallFormat(forModelType: "spark2_5") == .glm4)
        #expect(MLXBrainProvider.resolveToolCallFormat(
            for: ModelConfiguration(id: "abenzerps/Spark-X2.6-4B-MLX-4bit")
        ) == .glm4)
        #expect(MLXBrainProvider.resolveToolCallFormat(
            for: ModelConfiguration(id: "XHToken/Spark-X2.5-4B")
        ) == .glm4)
    }

    @Test("the type match is exact, and the existing families resolve as before")
    func existingFamiliesUnchanged() {
        #expect(MLXBrainProvider.toolCallFormat(forModelType: "spark2_5x") == nil)
        #expect(MLXBrainProvider.toolCallFormat(forModelType: "glm4") == .glm4)
        #expect(MLXBrainProvider.resolveToolCallFormat(for: ModelConfiguration(id: "zai/GLM-4.7-Flash")) == .glm4)
        #expect(MLXBrainProvider.resolveToolCallFormat(for: ModelConfiguration(id: "mlx-community/Phi-4-mini")) == .json)
        #expect(MLXBrainProvider.resolveToolCallFormat(for: ModelConfiguration(id: "mlx-community/gemma-4-12B-it-4bit")) == .gemma4)
        #expect(MLXBrainProvider.resolveToolCallFormat(for: ModelConfiguration(id: "LiquidAI/LFM2.5-1.2B")) == .lfm2)
    }

    @Test("eight concurrent first callers all wait for the one registration before loading")
    func concurrentRegistration() async throws {
        // The once-flag this replaced set its flag BEFORE awaiting the actor, so a racing
        // second caller could reach the factory first and get `unsupportedModelType`.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 8 {
                group.addTask { await Spark25Model.registerIfNeeded() }
            }
        }
        await #expect(throws: DecodingError.self) {
            try await LLMTypeRegistry.shared.createModel(
                configuration: Data("{}".utf8), modelType: Spark25Configuration.modelType
            )
        }
    }

    @Test("registration is idempotent and leaves the type creatable")
    func registers() async throws {
        await Spark25Model.registerIfNeeded()
        await Spark25Model.registerIfNeeded()
        // An unknown type throws `unsupportedModelType`; the registered one gets as
        // far as decoding, so a config with no `hidden_size` fails on the key, not the type.
        await #expect(throws: DecodingError.self) {
            try await LLMTypeRegistry.shared.createModel(
                configuration: Data("{}".utf8), modelType: Spark25Configuration.modelType
            )
        }
    }
}
