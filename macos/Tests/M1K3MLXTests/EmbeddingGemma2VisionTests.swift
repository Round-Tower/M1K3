//
//  EmbeddingGemma2VisionTests.swift
//  M1K3MLXTests
//
//  The pure half of the EmbeddingGemma 2 vision path (#836): the vision configuration decoded from
//  the real checkpoint's config.json, the parameter paths the tower declares against the checkpoint's
//  weight index, the vision key filter, the processor's size arithmetic and resampling weights, and the
//  image token layout. The numeric half (vectors against mlx-vlm's) runs inside the app:
//  EmbeddingGemma2RefStage, `M1K3_SELFTEST_EG2REF=1` — the metallib wall keeps it out of `swift test`.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-15, Confidence 0.8. Prior: none (new file).

import Foundation
@testable import M1K3MLX
import Testing

struct EmbeddingGemma2VisionTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func vision() throws -> EmbeddingGemma2VisionConfiguration {
        try #require(try EmbeddingGemma2VisionConfiguration.decode(from: fixture("embeddinggemma2-config")))
    }

    @Test("the checkpoint's config.json decodes to the 170M vision tower and the image markers")
    func decodesVision() throws {
        let config = try vision()
        #expect(config.hiddenLayers == 16)
        #expect(config.hiddenSize == 768)
        #expect(config.intermediateSize == 3072)
        #expect(config.attentionHeads == 12)
        #expect(config.keyValueHeads == 12)
        #expect(config.headDim == 64)
        #expect(config.patchSize == 16)
        #expect(config.poolingKernelSize == 3)
        #expect(config.positionEmbeddingSize == 10240)
        #expect(config.ropeTheta == 100)
        #expect(config.rmsNormEps == 1e-6)
        #expect(config.imageTokenID == 258_880)
        #expect(config.beginImageTokenID == 255_999)
        #expect(config.endImageTokenID == 258_882)
    }

    @Test("a text-only checkpoint has no vision tower; a clipped or standardised one is refused")
    func absentOrUnsupported() throws {
        let textOnly = Data(#"{"model_type": "embedding_gemma2", "text_config": {}}"#.utf8)
        #expect(try EmbeddingGemma2VisionConfiguration.decode(from: textOnly) == nil)
        for flag in ["use_clipped_linears", "standardize"] {
            let json = """
            {"model_type": "embedding_gemma2", "image_token_id": 258880, "boi_token_id": 255999,
             "eoi_token_id": 258882, "vision_config": {"\(flag)": true}}
            """
            #expect(throws: EmbeddingGemma2Error.self, "\(flag)") {
                try EmbeddingGemma2VisionConfiguration.decode(from: Data(json.utf8))
            }
        }
    }

    @Test("the tower's parameter paths are exactly the checkpoint's vision_tower.* and embed_vision.* keys")
    func parameterPathsMatchCheckpoint() throws {
        struct Keys: Decodable {
            struct Pattern: Decodable {
                let key: String
                let count: Int
            }

            let visionKeys: Int
            let visionPatterns: [Pattern]
        }
        let keys = try JSONDecoder().decode(Keys.self, from: fixture("embeddinggemma2-weight-keys"))
        let expected = try EmbeddingGemma2VisionStack.weightKeys(for: vision())
        #expect(expected.count == keys.visionKeys)
        var folded: [String: Int] = [:]
        for key in expected {
            folded[key.replacing(#/\.layers\.\d+\./#, with: ".layers.N."), default: 0] += 1
        }
        let fixturePatterns = Dictionary(uniqueKeysWithValues: keys.visionPatterns.map { ($0.key, $0.count) })
        #expect(folded == fixturePatterns)
    }

    @Test("the vision filter keeps vision_tower.* and embed_vision.* and nothing of the text or audio side")
    func visionKeyFilter() {
        #expect(EmbeddingGemma2VisionStack.visionKey("vision_tower.patch_embedder.input_proj.weight")
            == "vision_tower.patch_embedder.input_proj.weight")
        #expect(EmbeddingGemma2VisionStack.visionKey("model.embed_vision.embedding_projection.weight")
            == "embed_vision.embedding_projection.weight")
        #expect(EmbeddingGemma2VisionStack.visionKey("language_model.layers.0.mlp.up_proj.weight") == nil)
        #expect(EmbeddingGemma2VisionStack.visionKey("embed_tokens.weight") == nil)
        #expect(EmbeddingGemma2VisionStack.visionKey("audio_tower.layers.0.norm_out.weight") == nil)
        #expect(EmbeddingGemma2VisionStack.visionKey("embed_audio.embedding_projection.scales") == nil)
    }
}

struct EmbeddingGemma2ImageProcessorTests {
    private let processor = EmbeddingGemma2ImageProcessor(patchSize: 16, poolingKernelSize: 3, maxSoftTokens: 280)

    /// (width, height) → the target the reference processor (and so mlx-vlm's fixture) used.
    private static let sizes: [(width: Int, height: Int, targetWidth: Int, targetHeight: Int, tokens: Int)] = [
        (640, 480, 912, 672, 266),
        (640, 400, 1008, 624, 273),
        (480, 640, 672, 912, 266),
        (400, 400, 768, 768, 256),
        (320, 240, 912, 672, 266),
        (4032, 3024, 912, 672, 266),
    ]

    @Test("the target size keeps the aspect, fits the 280-token budget, and is a multiple of 48 per side",
          arguments: sizes)
    func targetSize(
        _ row: (width: Int, height: Int, targetWidth: Int, targetHeight: Int, tokens: Int)
    ) {
        let (height, width) = processor.targetSize(height: row.height, width: row.width)
        #expect(width == row.targetWidth)
        #expect(height == row.targetHeight)
        #expect(width % 48 == 0 && height % 48 == 0)
        #expect(processor.softTokenCount(height: height, width: width) == row.tokens)
        #expect(row.tokens <= 280)
    }

    @Test("an extreme aspect clamps the short side to one pooling cell instead of collapsing to zero")
    func extremeAspect() {
        let (height, width) = processor.targetSize(height: 40, width: 12000)
        #expect(height == 48)
        #expect(width > 48 && width % 48 == 0)
        #expect(processor.softTokenCount(height: height, width: width) >= 1)
    }

    @Test("the resampling weights: each output row sums to 1; the same size is the identity")
    func bicubicWeights() {
        let down = EmbeddingGemma2ImageProcessor.bicubicWeights(input: 640, output: 912)
        for row in 0 ..< 912 {
            let sum = down[row * 640 ..< (row + 1) * 640].reduce(0, +)
            #expect(abs(sum - 1) < 1e-5, "row \(row)")
        }
        let shrink = EmbeddingGemma2ImageProcessor.bicubicWeights(input: 1000, output: 250)
        for row in 0 ..< 250 {
            let sum = shrink[row * 1000 ..< (row + 1) * 1000].reduce(0, +)
            #expect(abs(sum - 1) < 1e-5, "shrink row \(row)")
        }
        let identity = EmbeddingGemma2ImageProcessor.bicubicWeights(input: 5, output: 5)
        for row in 0 ..< 5 {
            for column in 0 ..< 5 {
                #expect(abs(identity[row * 5 + column] - (row == column ? 1 : 0)) < 1e-6)
            }
        }
    }

    @Test("processor_config.json's image_processor block sets the budget, the patch and the pooling")
    func readsProcessorConfiguration() throws {
        let json = #"""
        {"image_processor": {"max_soft_tokens": 140, "patch_size": 16, "pooling_kernel_size": 3,
                              "do_normalize": false}}
        """#
        let configured = try EmbeddingGemma2ImageProcessor(processorConfiguration: Data(json.utf8))
        #expect(configured.maxSoftTokens == 140)
        let (height, width) = configured.targetSize(height: 480, width: 640)
        #expect(configured.softTokenCount(height: height, width: width) <= 140)
        let normalising = #"{"image_processor": {"do_normalize": true}}"#
        #expect(throws: EmbeddingGemma2Error.self) {
            try EmbeddingGemma2ImageProcessor(processorConfiguration: Data(normalising.utf8))
        }
    }

    @Test("an image is <bos> <boi> soft×n <eoi> <eos> with no prompt text, under its own prompt version")
    func imageSequence() throws {
        let data = try Data(contentsOf: #require(Bundle.module.url(
            forResource: "embeddinggemma2-config", withExtension: "json", subdirectory: "Fixtures"
        )))
        let config = try #require(try EmbeddingGemma2VisionConfiguration.decode(from: data))
        let ids = EmbeddingGemma2ImagePath.tokens(softTokens: 4, vision: config, beginOfSequence: 2, endOfSequence: 1)
        #expect(ids == [2, 255_999, 258_880, 258_880, 258_880, 258_880, 258_882, 1])
        #expect(EmbeddingGemma2ImagePath.promptVersion == "image-prompt-v1")
    }
}
