//
//  EmbeddingGemma2Vision.swift
//  M1K3MLX
//
//  EmbeddingGemma 2's vision encoder (the checkpoint's `vision_tower.*` and `embed_vision.*`): the
//  Gemma 4 vision tower — patch embedding with learned x/y position tables, 16 bidirectional layers
//  with axial RoPE, 3×3 average pooling to at most 280 soft tokens — and the projection that maps
//  those tokens into the text core's 512-wide token space, so an image embeds into the same 768-d
//  space as text (EmbeddingGemma2.swift is the text core; EmbeddingGemma2ImagePath.swift is how an
//  image reaches this tower).
//
//  Upstream credit (MIT): ported from ml-explore/mlx-swift-lm PR #684 ("Add EmbeddingGemma 2 full
//  support", merged 2026-10-12, in no tagged release yet — our pin is the 3.32.x tag line on purpose,
//  see Package.swift), files `Libraries/MLXLMCommon/Models/Gemma4Encoders.swift` (the vision part: no  claims: skip (upstream paths)
//  audio), `Libraries/MLXLMCommon/Models/EmbeddingGemma2.swift` and `Libraries/MLXVLM/EmbeddingGemma2.swift`.  claims: skip
//  Copyright © 2026 Apple Inc. Differences: prefixed names (MLXVLM's own Gemma4 types stay untouched),
//  the unused paths dropped (clipped linears and standardisation — EmbeddingGemma 2 ships neither, and the
//  configuration refuses a checkpoint that does), and the 2-D position branch of the RoPE. Checked against
//  mlx-vlm 3d87e884's vectors by EmbeddingGemma2RefStage, not here.
//
//  Shape notes that are easy to get wrong:
//  - The tower's weights are bf16, not quantised (the 8-bit policy covers the text encoder and the audio
//    projection only): no scales or biases, and `Linear` loads as-is.
//  - Pixels are 0...1; the patch embedder maps them to -1...1. There is no mean/std normalisation.
//  - Attention scale is 1.0 (q/k RMSNorms carry it); v is RMS-normed with no learned weight.
//  - The soft tokens REPLACE the image placeholder embeddings after the text scaling (no sqrt(hidden)).
//
//  Signed: Kev + claude-opus-5.5, 2026-11-15, Confidence 0.75. Prior: none (new file; #836, GEMMA_1_1_PLAN
//  Stream D). Open: numeric parity is proven by the in-app reference stage, not by `swift test`.

import Foundation
import MLX
import MLXFast
import MLXLMCommon
import MLXNN

// MARK: - Configuration

/// The vision fields of EmbeddingGemma 2's `config.json`: the tower layout and the three marker tokens.
public struct EmbeddingGemma2VisionConfiguration: Sendable, Equatable {
    public let hiddenLayers: Int
    public let hiddenSize: Int
    public let intermediateSize: Int
    public let attentionHeads: Int
    public let keyValueHeads: Int
    public let headDim: Int
    public let patchSize: Int
    public let rmsNormEps: Float
    public let positionEmbeddingSize: Int
    public let poolingKernelSize: Int
    public let ropeTheta: Float
    /// The placeholder repeated once per soft token, and the markers around the run.
    public let imageTokenID: Int
    public let beginImageTokenID: Int
    public let endImageTokenID: Int

    private struct Tower: Decodable {
        struct Rope: Decodable {
            let ropeTheta: Float?

            enum CodingKeys: String, CodingKey {
                case ropeTheta = "rope_theta"
            }
        }

        let hiddenLayers: Int?
        let hiddenSize: Int?
        let intermediateSize: Int?
        let attentionHeads: Int?
        let keyValueHeads: Int?
        let headDim: Int?
        let patchSize: Int?
        let rmsNormEps: Float?
        let positionEmbeddingSize: Int?
        let poolingKernelSize: Int?
        let useClippedLinears: Bool?
        let standardize: Bool?
        let ropeParameters: Rope?

        enum CodingKeys: String, CodingKey {
            case hiddenLayers = "num_hidden_layers"
            case hiddenSize = "hidden_size"
            case intermediateSize = "intermediate_size"
            case attentionHeads = "num_attention_heads"
            case keyValueHeads = "num_key_value_heads"
            case headDim = "head_dim"
            case patchSize = "patch_size"
            case rmsNormEps = "rms_norm_eps"
            case positionEmbeddingSize = "position_embedding_size"
            case poolingKernelSize = "pooling_kernel_size"
            case useClippedLinears = "use_clipped_linears"
            case standardize
            case ropeParameters = "rope_parameters"
        }
    }

    private struct Root: Decodable {
        let visionConfig: Tower?
        let imageTokenID: Int?
        let beginImageTokenID: Int?
        let endImageTokenID: Int?

        enum CodingKeys: String, CodingKey {
            case visionConfig = "vision_config"
            case imageTokenID = "image_token_id"
            case beginImageTokenID = "boi_token_id"
            case endImageTokenID = "eoi_token_id"
        }
    }

    /// The vision configuration of a checkpoint's `config.json`; nil when it declares no vision tower
    /// (a text-only conversion). Throws for a tower this port does not cover (clipped linears or
    /// standardisation — EmbeddingGemma 2 ships neither).
    public static func decode(from configData: Data) throws -> EmbeddingGemma2VisionConfiguration? {
        let root = try JSONDecoder.json5().decode(Root.self, from: configData)
        guard let tower = root.visionConfig, let image = root.imageTokenID,
              let begin = root.beginImageTokenID, let end = root.endImageTokenID
        else { return nil }
        guard tower.useClippedLinears != true, tower.standardize != true else {
            throw EmbeddingGemma2Error.unsupportedVision("clipped linears or standardisation")
        }
        // The defaults are the Gemma 4 vision tower's (what a bare `vision_config` means).
        let heads = tower.attentionHeads ?? 12
        return EmbeddingGemma2VisionConfiguration(
            hiddenLayers: tower.hiddenLayers ?? 16, hiddenSize: tower.hiddenSize ?? 768,
            intermediateSize: tower.intermediateSize ?? 3072, attentionHeads: heads,
            keyValueHeads: tower.keyValueHeads ?? heads, headDim: tower.headDim ?? 64,
            patchSize: tower.patchSize ?? 16, rmsNormEps: tower.rmsNormEps ?? 1e-6,
            positionEmbeddingSize: tower.positionEmbeddingSize ?? 10240,
            poolingKernelSize: tower.poolingKernelSize ?? 3,
            ropeTheta: tower.ropeParameters?.ropeTheta ?? 100,
            imageTokenID: image, beginImageTokenID: begin, endImageTokenID: end
        )
    }
}

// MARK: - Guard

/// Runs MLX work inside an error scope so a failure (a truncated or mismatched checkpoint, a GPU error) throws
/// instead of reaching MLX's no-handler fatalError. The same pattern as `KokoroGuardedRead` (M1K3Kokoro, which this
/// target cannot import). Errors that are already `EmbeddingGemma2Error` pass through; anything else is wrapped.
enum EmbeddingGemma2Guard {
    static func run<R>(_ body: () throws -> R) throws -> R {
        do {
            return try withError { failure in
                let result = try body()
                try failure.check()
                return result
            }
        } catch let error as EmbeddingGemma2Error {
            throw error
        } catch {
            throw EmbeddingGemma2Error.visionFailed(String(describing: error))
        }
    }
}

// MARK: - Stack

/// `vision_tower` + `embed_vision`: pixels `[B, 3, H, W]` → `[B, soft tokens, textHidden]`.
final class EmbeddingGemma2VisionStack: Module {
    @ModuleInfo(key: "vision_tower") var tower: EmbeddingGemma2VisionTower
    @ModuleInfo(key: "embed_vision") var projection: EmbeddingGemma2VisionProjection

    init(_ config: EmbeddingGemma2VisionConfiguration, textHiddenSize: Int) {
        _tower.wrappedValue = EmbeddingGemma2VisionTower(config)
        _projection.wrappedValue = EmbeddingGemma2VisionProjection(
            visionSize: config.hiddenSize, textSize: textHiddenSize, eps: config.rmsNormEps
        )
        super.init()
    }

    func callAsFunction(_ pixels: MLXArray) -> MLXArray {
        projection(tower(pixels))
    }

    /// The checkpoint key a vision tensor loads under, or nil for everything else (text core, audio).
    /// Pure, so the filter is unit-tested without MLX.
    static func visionKey(_ key: String) -> String? {
        var key = key
        if key.hasPrefix("model.") { key.removeFirst("model.".count) }
        return key.hasPrefix("vision_tower.") || key.hasPrefix("embed_vision.") ? key : nil
    }

    /// Every parameter path the stack declares for `config` — all bare weights (bf16, unquantised).
    /// Pure: pinned against the checkpoint's weight index by EmbeddingGemma2VisionTests.
    static func weightKeys(for config: EmbeddingGemma2VisionConfiguration) -> [String] {
        var keys = [
            "vision_tower.patch_embedder.input_proj.weight",
            "vision_tower.patch_embedder.position_embedding_table",
            "embed_vision.embedding_projection.weight",
        ]
        for index in 0 ..< config.hiddenLayers {
            let layer = "vision_tower.encoder.layers.\(index)"
            for norm in [
                "input_layernorm", "post_attention_layernorm", "pre_feedforward_layernorm",
                "post_feedforward_layernorm",
            ] {
                keys.append("\(layer).\(norm).weight")
            }
            for projection in ["q_proj", "k_proj", "v_proj", "o_proj"] {
                keys.append("\(layer).self_attn.\(projection).linear.weight")
            }
            keys += ["\(layer).self_attn.q_norm.weight", "\(layer).self_attn.k_norm.weight"]
            for projection in ["gate_proj", "up_proj", "down_proj"] {
                keys.append("\(layer).mlp.\(projection).linear.weight")
            }
        }
        return keys
    }
}

/// Maps the tower's soft tokens into the text core's token space.
final class EmbeddingGemma2VisionProjection: Module {
    @ModuleInfo(key: "embedding_projection") var projection: Linear
    private let eps: Float

    init(visionSize: Int, textSize: Int, eps: Float) {
        self.eps = eps
        _projection.wrappedValue = Linear(visionSize, textSize, bias: false)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        // `embedding_pre_projection_norm` has no learned weight.
        let unit = MLXArray.ones([x.dim(-1)]).asType(x.dtype)
        return projection(MLXFast.rmsNorm(x, weight: unit, eps: eps))
    }
}

// MARK: - Tower

final class EmbeddingGemma2VisionTower: Module {
    @ModuleInfo(key: "patch_embedder") var patchEmbedder: EmbeddingGemma2VisionPatchEmbedder
    @ModuleInfo(key: "encoder") var encoder: EmbeddingGemma2VisionEncoder

    private let patchSize: Int
    private let poolingKernelSize: Int
    private let hiddenSize: Int

    init(_ config: EmbeddingGemma2VisionConfiguration) {
        patchSize = config.patchSize
        poolingKernelSize = config.poolingKernelSize
        hiddenSize = config.hiddenSize
        _patchEmbedder.wrappedValue = EmbeddingGemma2VisionPatchEmbedder(config)
        _encoder.wrappedValue = EmbeddingGemma2VisionEncoder(config)
        super.init()
    }

    /// `[B, 3, H, W]` pixels in 0...1 (H and W multiples of `patchSize × poolingKernelSize`, every patch
    /// real — so attention is dense) → `[B, H/p × W/p / k², hidden]`.
    func callAsFunction(_ pixels: MLXArray) -> MLXArray {
        let batch = pixels.dim(0)
        let patchesHigh = pixels.dim(2) / patchSize
        let patchesWide = pixels.dim(3) / patchSize
        let count = patchesHigh * patchesWide
        let outputLength = max(count / (poolingKernelSize * poolingKernelSize), 1)

        // x varies fastest, matching the row-major patch order.
        let grid = meshGrid([MLXArray.arange(patchesWide, dtype: .int32), MLXArray.arange(patchesHigh, dtype: .int32)])
        let positions = stacked([grid[0].flattened(), grid[1].flattened()], axis: 1).reshaped(1, count, 2)
        let batched = batch == 1 ? positions : broadcast(positions, to: [batch, count, 2])

        let embedded = patchEmbedder(pixels, positions: batched)
        let encoded = encoder(embedded, positions: batched)
        return pool(encoded, positions: batched[0], patchesWide: patchesWide, outputLength: outputLength)
    }

    /// Average pooling over `k × k` patch cells as one `[l, L]` weight matrix (every row shares one grid),
    /// then the `sqrt(hidden)` scale.
    private func pool(_ x: MLXArray, positions: MLXArray, patchesWide: Int, outputLength: Int) -> MLXArray {
        let scale = MLXArray(Float(hiddenSize).squareRoot(), dtype: x.dtype)
        let count = x.dim(1)
        let length = max(outputLength, 1)
        if count <= length { return x * scale }
        let kernel = max(Int(Double(count / length).squareRoot()), 1)
        let cell = floor(positions.asType(.float32) / Float(kernel)).asType(.int32)
        let flat = cell[0..., 0] + MLXArray(Int32(max(patchesWide / kernel, 1))) * cell[0..., 1]
        let hot = flat.expandedDimensions(axis: -1) .== MLXArray(0 ..< length)
        let weights = hot.asType(.float32) / Float(kernel * kernel)
        return einsum("lL,bld->bLd", weights, x).asType(x.dtype) * scale
    }
}

final class EmbeddingGemma2VisionPatchEmbedder: Module {
    @ModuleInfo(key: "input_proj") var inputProjection: Linear
    @ParameterInfo(key: "position_embedding_table") var positionTable: MLXArray

    private let patchSize: Int
    private let hiddenSize: Int

    init(_ config: EmbeddingGemma2VisionConfiguration) {
        patchSize = config.patchSize
        hiddenSize = config.hiddenSize
        _inputProjection.wrappedValue = Linear(3 * config.patchSize * config.patchSize, config.hiddenSize, bias: false)
        _positionTable.wrappedValue = MLXArray.ones([2, config.positionEmbeddingSize, config.hiddenSize])
        super.init()
    }

    func callAsFunction(_ pixels: MLXArray, positions: MLXArray) -> MLXArray {
        let (batch, channels, height, width) = (pixels.dim(0), pixels.dim(1), pixels.dim(2), pixels.dim(3))
        let high = height / patchSize
        let wide = width / patchSize
        var patches = pixels.reshaped(batch, channels, high, patchSize, wide, patchSize)
        patches = patches.transposed(0, 2, 4, 3, 5, 1).reshaped(batch, high * wide, channels * patchSize * patchSize)
        patches = 2 * (patches - 0.5)
        let hidden = inputProjection(patches.asType(inputProjection.weight.dtype))

        let count = positions.dim(1)
        let xs = positions[0..., 0..., 0].flattened().asType(.int32)
        let ys = positions[0..., 0..., 1].flattened().asType(.int32)
        let xEmbeddings = take(positionTable[0], xs, axis: 0).reshaped(batch, count, hiddenSize)
        let yEmbeddings = take(positionTable[1], ys, axis: 0).reshaped(batch, count, hiddenSize)
        return hidden + xEmbeddings + yEmbeddings
    }
}

final class EmbeddingGemma2VisionEncoder: Module {
    @ModuleInfo(key: "layers") var layers: [EmbeddingGemma2VisionLayer]

    init(_ config: EmbeddingGemma2VisionConfiguration) {
        _layers.wrappedValue = (0 ..< config.hiddenLayers).map { _ in EmbeddingGemma2VisionLayer(config) }
        super.init()
    }

    func callAsFunction(_ x: MLXArray, positions: MLXArray) -> MLXArray {
        var hidden = x
        for layer in layers {
            hidden = layer(hidden, positions: positions)
            // One layer at a time: left lazy, the 16-layer graph over ~2,400 patches holds ~700 MB of intermediates
            // at once (measured: MLX peak 1.31 GB against 0.59 GB of weights); this keeps the peak near one layer's.
            eval(hidden)
        }
        return hidden
    }
}

/// A `Linear` stored one level down (`<name>.linear.weight`), as the checkpoint names the tower's projections.
final class EmbeddingGemma2VisionLinear: Module {
    @ModuleInfo(key: "linear") var linear: Linear

    init(_ inputSize: Int, _ outputSize: Int) {
        _linear.wrappedValue = Linear(inputSize, outputSize, bias: false)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        linear(x)
    }
}

/// RMSNorm over the last axis with a learned scale applied directly (Gemma 4), computed in float32.
final class EmbeddingGemma2VisionNorm: Module {
    @ParameterInfo(key: "weight") var weight: MLXArray
    private let eps: Float

    init(_ size: Int, eps: Float) {
        self.eps = eps
        _weight.wrappedValue = MLXArray.ones([size])
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let wide = x.asType(.float32)
        let normalised = wide * rsqrt(mean(wide.square(), axis: -1, keepDims: true) + eps)
        return (normalised * weight.asType(.float32)).asType(x.dtype)
    }
}

final class EmbeddingGemma2VisionLayer: Module {
    @ModuleInfo(key: "self_attn") var attention: EmbeddingGemma2VisionAttention
    @ModuleInfo(key: "mlp") var mlp: EmbeddingGemma2VisionMLP
    @ModuleInfo(key: "input_layernorm") var inputNorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionNorm: RMSNorm
    @ModuleInfo(key: "pre_feedforward_layernorm") var preFeedforwardNorm: RMSNorm
    @ModuleInfo(key: "post_feedforward_layernorm") var postFeedforwardNorm: RMSNorm

    init(_ config: EmbeddingGemma2VisionConfiguration) {
        _attention.wrappedValue = EmbeddingGemma2VisionAttention(config)
        _mlp.wrappedValue = EmbeddingGemma2VisionMLP(config)
        _inputNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        _postAttentionNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        _preFeedforwardNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        _postFeedforwardNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, positions: MLXArray) -> MLXArray {
        let hidden = x + postAttentionNorm(attention(inputNorm(x), positions: positions))
        return hidden + postFeedforwardNorm(mlp(preFeedforwardNorm(hidden)))
    }
}

final class EmbeddingGemma2VisionAttention: Module {
    @ModuleInfo(key: "q_proj") var qProj: EmbeddingGemma2VisionLinear
    @ModuleInfo(key: "k_proj") var kProj: EmbeddingGemma2VisionLinear
    @ModuleInfo(key: "v_proj") var vProj: EmbeddingGemma2VisionLinear
    @ModuleInfo(key: "o_proj") var oProj: EmbeddingGemma2VisionLinear
    @ModuleInfo(key: "q_norm") var qNorm: EmbeddingGemma2VisionNorm
    @ModuleInfo(key: "k_norm") var kNorm: EmbeddingGemma2VisionNorm

    private let heads: Int
    private let kvHeads: Int
    private let headDim: Int
    private let eps: Float
    private let ropeBase: Float

    init(_ config: EmbeddingGemma2VisionConfiguration) {
        heads = config.attentionHeads
        kvHeads = config.keyValueHeads
        headDim = config.headDim
        eps = config.rmsNormEps
        ropeBase = config.ropeTheta
        _qProj.wrappedValue = EmbeddingGemma2VisionLinear(config.hiddenSize, heads * headDim)
        _kProj.wrappedValue = EmbeddingGemma2VisionLinear(config.hiddenSize, kvHeads * headDim)
        _vProj.wrappedValue = EmbeddingGemma2VisionLinear(config.hiddenSize, kvHeads * headDim)
        _oProj.wrappedValue = EmbeddingGemma2VisionLinear(heads * headDim, config.hiddenSize)
        _qNorm.wrappedValue = EmbeddingGemma2VisionNorm(headDim, eps: config.rmsNormEps)
        _kNorm.wrappedValue = EmbeddingGemma2VisionNorm(headDim, eps: config.rmsNormEps)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, positions: MLXArray) -> MLXArray {
        let (batch, length) = (x.dim(0), x.dim(1))
        var queries = qNorm(qProj(x).reshaped(batch, length, heads, headDim))
        var keys = kNorm(kProj(x).reshaped(batch, length, kvHeads, headDim))
        // v is RMS-normed in float32 with no learned scale.
        let rawValues = vProj(x).reshaped(batch, length, kvHeads, headDim)
        let wide = rawValues.asType(.float32)
        let values = (wide * rsqrt(mean(wide.square(), axis: -1, keepDims: true) + eps)).asType(rawValues.dtype)

        queries = Self.rotate(queries, positions: positions, base: ropeBase)
        keys = Self.rotate(keys, positions: positions, base: ropeBase)
        let output = MLXFast.scaledDotProductAttention(
            queries: queries.transposed(0, 2, 1, 3), keys: keys.transposed(0, 2, 1, 3),
            values: values.transposed(0, 2, 1, 3), scale: 1, mask: nil
        )
        return oProj(output.transposed(0, 2, 1, 3).reshaped(batch, length, -1))
    }

    /// Axial RoPE: the head's channels split in two halves, one rotated by the patch's x, the other by its y.
    static func rotate(_ inputs: MLXArray, positions: MLXArray, base: Float) -> MLXArray {
        let headDim = inputs.dim(-1)
        let dimensions = positions.dim(-1)
        let perAxis = 2 * (headDim / (2 * dimensions))
        let half = perAxis / 2
        var parts: [MLXArray] = []
        for axis in 0 ..< dimensions {
            let part = inputs[.ellipsis, axis * perAxis ..< (axis + 1) * perAxis]
            let exponents = (2.0 / Float(perAxis)) * MLXArray(0 ..< half).asType(.float32)
            let timescale = MLX.pow(MLXArray(base), exponents)
            let angle = positions[.ellipsis, axis ..< axis + 1].asType(.float32) / timescale
            let cosine = concatenated([cos(angle), cos(angle)], axis: -1).asType(inputs.dtype).expandedDimensions(axis: 2)
            let sine = concatenated([sin(angle), sin(angle)], axis: -1).asType(inputs.dtype).expandedDimensions(axis: 2)
            let left = part[.ellipsis, ..<half]
            let right = part[.ellipsis, half...]
            parts.append(part * cosine + concatenated([-right, left], axis: -1) * sine)
        }
        return concatenated(parts, axis: -1)
    }
}

final class EmbeddingGemma2VisionMLP: Module {
    @ModuleInfo(key: "gate_proj") var gateProj: EmbeddingGemma2VisionLinear
    @ModuleInfo(key: "up_proj") var upProj: EmbeddingGemma2VisionLinear
    @ModuleInfo(key: "down_proj") var downProj: EmbeddingGemma2VisionLinear

    init(_ config: EmbeddingGemma2VisionConfiguration) {
        _gateProj.wrappedValue = EmbeddingGemma2VisionLinear(config.hiddenSize, config.intermediateSize)
        _upProj.wrappedValue = EmbeddingGemma2VisionLinear(config.hiddenSize, config.intermediateSize)
        _downProj.wrappedValue = EmbeddingGemma2VisionLinear(config.intermediateSize, config.hiddenSize)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        downProj(geluApproximate(gateProj(x)) * upProj(x))
    }
}
