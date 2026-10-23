//
//  Spark25.swift
//  M1K3MLX
//
//  Spark-X2.5 / X2.6 (`XHToken/Spark-X2.6-4B`, `model_type: spark2_5`) as an
//  mlx-swift-lm `LLMModel`: 36 layers in a 3 sliding(512) : 1 full pattern, a fused
//  q_k_v projection, a head-wise sigmoid output gate on attention, partial rotary
//  (0.25 of head_dim on the full layers, all of it on the sliding ones), GELU gated
//  MLP, tied embeddings.
//
//  Why our own file: mlx-swift-lm at our pin (3.32.3) and upstream main have no
//  Spark model; mlx-lm (Python) merged `models/spark2_5.py` and that is what this
//  ports (sanitize is a superset: it maps the quantised `.scales`/`.biases` too),
//  with Gemma3Text.swift as the Swift idiom for the hybrid sliding/full cache and
//  the inner-model prefill. Registered into `LLMTypeRegistry.shared` by
//  `Spark25Model.registerIfNeeded()`, which the brain provider calls before every
//  factory load, so a checkpoint with `model_type: spark2_5` loads through the
//  ordinary `LLMModelFactory` path.
//
//  Shape notes that are easy to get wrong:
//  - The gate `g_proj` is [hidden → heads] and is applied AFTER attention, per
//    head, in float32 then cast back: `out * sigmoid(g)[..., None]`.
//  - The embedding key is `model.embedding` (not `embed_tokens`); some conversions
//    rename it, so `sanitize` maps `embed_tokens` back.
//  - The 4-bit conversions leave `g_proj` unquantised (mlx-lm's quant_predicate);
//    the loader's `.scales` check handles that per module, nothing to do here.
//  - RoPE offset is the ABSOLUTE position (the cache's offset), so a rotating
//    sliding cache stays correct after it wraps — `applyRotaryPosition` reads it.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-21, Confidence 0.7, Prior: none (new file;
//  the Spark-X2.6 audition, in isolation). Port of mlx-lm 0.32.2's spark2_5.py.
//  Open: numeric parity against the Python rig is the in-app chateval's to prove
//  (the metallib wall keeps model code out of `swift test`); the pure parts
//  (config, layer pattern, sanitize keys, dialect) are pinned in Spark25Tests.
//  Open: `registerModelType` replaces the registry entry wholesale, so if a
//  mlx-swift-lm bump ships its own `spark2_5`, ours silently wins — drop this
//  file on that bump. Open: the audition is parked on the vision rule
//  (docs/evals/2026-10-21-spark-x26-audition.md).
//  Review: Kev + claude-fable-5.1, 2026-10-21 (pre-push review fold) — the once-flag
//  raced the actor (set before the await); it is one shared Task now. `prepare`
//  prefills through the inner model, capped at the window. Rotary width in Double.
//

import Foundation
import MLX
import MLXFast
import MLXLLM
import MLXLMCommon
import MLXNN

// MARK: - Configuration

/// `config.json` for `model_type: spark2_5`.
public struct Spark25Configuration: Codable, Sendable {
    public struct RoPEParameters: Codable, Sendable, Equatable {
        public var partialRotaryFactor: Float
        public var ropeTheta: Float

        enum CodingKeys: String, CodingKey {
            case partialRotaryFactor = "partial_rotary_factor"
            case ropeTheta = "rope_theta"
        }

        public init(partialRotaryFactor: Float = 1.0, ropeTheta: Float = 10000) {
            self.partialRotaryFactor = partialRotaryFactor
            self.ropeTheta = ropeTheta
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            partialRotaryFactor = try c.decodeIfPresent(Float.self, forKey: .partialRotaryFactor) ?? 1.0
            ropeTheta = try c.decodeIfPresent(Float.self, forKey: .ropeTheta) ?? 10000
        }
    }

    public static let modelType = "spark2_5"
    public static let slidingLayer = "sliding_attention"
    public static let fullLayer = "full_attention"

    public var modelType: String
    public var hiddenSize: Int
    public var intermediateSize: Int
    public var hiddenLayers: Int
    public var attentionHeads: Int
    public var kvHeads: Int
    public var headDim: Int
    public var vocabularySize: Int
    public var slidingWindow: Int
    public var ropeParameters: [String: RoPEParameters]
    /// One entry per layer, `sliding_attention` or `full_attention`. Defaults to
    /// the reference 3:1 pattern when the checkpoint omits it.
    public var layerTypes: [String]
    public var rmsNormEps: Float
    public var maxPositionEmbeddings: Int
    public var attentionBias: Bool
    public var mlpBias: Bool
    public var hiddenAct: String
    public var gateAttnActMode: String
    public var headwiseAttnOutputGate: Bool
    public var tieWordEmbeddings: Bool

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case hiddenSize = "hidden_size"
        case intermediateSize = "intermediate_size"
        case hiddenLayers = "num_hidden_layers"
        case attentionHeads = "num_attention_heads"
        case kvHeads = "num_key_value_heads"
        case headDim = "head_dim"
        case vocabularySize = "vocab_size"
        case slidingWindow = "sliding_window"
        case ropeParameters = "rope_parameters"
        case layerTypes = "layer_types"
        case rmsNormEps = "rms_norm_eps"
        case maxPositionEmbeddings = "max_position_embeddings"
        case attentionBias = "attention_bias"
        case mlpBias = "mlp_bias"
        case hiddenAct = "hidden_act"
        case gateAttnActMode = "gate_attn_act_mode"
        case headwiseAttnOutputGate = "headwise_attn_output_gate"
        case tieWordEmbeddings = "tie_word_embeddings"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelType = try c.decodeIfPresent(String.self, forKey: .modelType) ?? Self.modelType
        hiddenSize = try c.decode(Int.self, forKey: .hiddenSize)
        intermediateSize = try c.decode(Int.self, forKey: .intermediateSize)
        hiddenLayers = try c.decode(Int.self, forKey: .hiddenLayers)
        attentionHeads = try c.decode(Int.self, forKey: .attentionHeads)
        kvHeads = try c.decode(Int.self, forKey: .kvHeads)
        headDim = try c.decode(Int.self, forKey: .headDim)
        vocabularySize = try c.decode(Int.self, forKey: .vocabularySize)
        slidingWindow = try c.decode(Int.self, forKey: .slidingWindow)
        ropeParameters = try c.decode([String: RoPEParameters].self, forKey: .ropeParameters)
        layerTypes = try c.decodeIfPresent([String].self, forKey: .layerTypes)
            ?? Self.defaultLayerTypes(count: hiddenLayers)
        rmsNormEps = try c.decodeIfPresent(Float.self, forKey: .rmsNormEps) ?? 1e-6
        maxPositionEmbeddings = try c.decodeIfPresent(Int.self, forKey: .maxPositionEmbeddings) ?? 8192
        attentionBias = try c.decodeIfPresent(Bool.self, forKey: .attentionBias) ?? false
        mlpBias = try c.decodeIfPresent(Bool.self, forKey: .mlpBias) ?? false
        hiddenAct = try c.decodeIfPresent(String.self, forKey: .hiddenAct) ?? "gelu"
        gateAttnActMode = try c.decodeIfPresent(String.self, forKey: .gateAttnActMode) ?? "sigmoid"
        headwiseAttnOutputGate = try c.decodeIfPresent(Bool.self, forKey: .headwiseAttnOutputGate) ?? true
        tieWordEmbeddings = try c.decodeIfPresent(Bool.self, forKey: .tieWordEmbeddings) ?? true
        try validate()
    }

    /// The reference pattern when `layer_types` is absent: three sliding, one full.
    static func defaultLayerTypes(count: Int) -> [String] {
        let pattern = [slidingLayer, slidingLayer, slidingLayer, fullLayer]
        return (0 ..< count).map { pattern[$0 % pattern.count] }
    }

    public func isSliding(layer index: Int) -> Bool {
        layerTypes[index] == Self.slidingLayer
    }

    /// The rotary width for a layer type: `head_dim × partial_rotary_factor`.
    public func ropeDimensions(for layerType: String) -> Int {
        // Double, as Python's `int(head_dim * factor)`: a Float product can truncate
        // differently for a factor that is not exactly representable.
        Int(Double(headDim) * Double(ropeParameters[layerType]?.partialRotaryFactor ?? 1.0))
    }

    public func ropeTheta(for layerType: String) -> Float {
        ropeParameters[layerType]?.ropeTheta ?? 10000
    }

    public var firstFullLayer: Int? {
        layerTypes.firstIndex(of: Self.fullLayer)
    }

    public var firstSlidingLayer: Int? {
        layerTypes.firstIndex(of: Self.slidingLayer)
    }

    /// The same refusals as the Python port: this file implements exactly one
    /// architecture, and a checkpoint outside it must fail at load, not drift.
    public func validate() throws {
        guard layerTypes.count == hiddenLayers else {
            throw Spark25Error.invalid("layer_types has \(layerTypes.count) entries for \(hiddenLayers) layers")
        }
        let unsupported = Set(layerTypes).subtracting([Self.slidingLayer, Self.fullLayer])
        guard unsupported.isEmpty else {
            throw Spark25Error.invalid("unsupported layer types \(unsupported.sorted())")
        }
        let missingRope = Set(layerTypes).subtracting(ropeParameters.keys)
        guard missingRope.isEmpty else {
            throw Spark25Error.invalid("rope_parameters missing for \(missingRope.sorted())")
        }
        guard attentionHeads % kvHeads == 0 else {
            throw Spark25Error.invalid("num_attention_heads must divide by num_key_value_heads")
        }
        for layerType in Set(layerTypes) {
            let dims = ropeDimensions(for: layerType)
            guard dims > 0, dims <= headDim, dims % 2 == 0 else {
                throw Spark25Error.invalid("rotary dimension \(dims) invalid for head_dim \(headDim)")
            }
        }
        guard hiddenAct == "gelu" else { throw Spark25Error.invalid("requires GELU, got \(hiddenAct)") }
        guard headwiseAttnOutputGate else { throw Spark25Error.invalid("requires head-wise attention output gates") }
        guard gateAttnActMode == "sigmoid" else {
            throw Spark25Error.invalid("requires sigmoid attention gates, got \(gateAttnActMode)")
        }
    }
}

public enum Spark25Error: Error, CustomStringConvertible, Equatable {
    case invalid(String)

    public var description: String {
        switch self {
        case let .invalid(reason): "Spark2_5 config: \(reason)"
        }
    }
}

// MARK: - Layers

final class Spark25Attention: Module {
    let nHeads: Int
    let nKVHeads: Int
    let headDim: Int
    let qSize: Int
    let kvSize: Int
    let scale: Float
    let isSliding: Bool

    @ModuleInfo(key: "q_k_v_proj") var qkvProj: Linear
    @ModuleInfo(key: "g_proj") var gateProj: Linear
    @ModuleInfo(key: "out_proj") var outProj: Linear

    let rope: RoPELayer

    init(_ config: Spark25Configuration, layerIndex: Int) {
        nHeads = config.attentionHeads
        nKVHeads = config.kvHeads
        headDim = config.headDim
        qSize = nHeads * headDim
        kvSize = nKVHeads * headDim
        scale = pow(Float(headDim), -0.5)
        let layerType = config.layerTypes[layerIndex]
        isSliding = layerType == Spark25Configuration.slidingLayer

        _qkvProj.wrappedValue = Linear(config.hiddenSize, qSize + 2 * kvSize, bias: config.attentionBias)
        _gateProj.wrappedValue = Linear(config.hiddenSize, nHeads, bias: config.attentionBias)
        _outProj.wrappedValue = Linear(qSize, config.hiddenSize, bias: config.attentionBias)
        rope = initializeRope(
            dims: config.ropeDimensions(for: layerType),
            base: config.ropeTheta(for: layerType),
            traditional: false, scalingConfig: nil,
            maxPositionEmbeddings: config.maxPositionEmbeddings
        )
        super.init()
    }

    func callAsFunction(
        _ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode, cache: KVCache?
    ) -> MLXArray {
        let (batch, length) = (x.dim(0), x.dim(1))
        let parts = split(qkvProj(x), indices: [qSize, qSize + kvSize], axis: -1)
        var queries = parts[0].reshaped(batch, length, nHeads, headDim).transposed(0, 2, 1, 3)
        var keys = parts[1].reshaped(batch, length, nKVHeads, headDim).transposed(0, 2, 1, 3)
        let values = parts[2].reshaped(batch, length, nKVHeads, headDim).transposed(0, 2, 1, 3)

        // Absolute position: the cache's offset, so a wrapped rotating cache is still right.
        let offset = cache?.ropeOffset
        queries = applyRotaryPosition(rope, to: queries, offset: offset)
        keys = applyRotaryPosition(rope, to: keys, offset: offset)

        var output = attentionWithCacheUpdate(
            queries: queries, keys: keys, values: values, cache: cache, scale: scale, mask: mask
        ).transposed(0, 2, 1, 3) // [B, L, heads, headDim]

        // Head-wise sigmoid gate, computed in float32 as the reference does.
        let gate = sigmoid(gateProj(x).asType(.float32)).asType(output.dtype) // [B, L, heads]
        output *= gate.expandedDimensions(axis: -1)
        return outProj(output.reshaped(batch, length, -1))
    }
}

final class Spark25MLP: Module, UnaryLayer {
    @ModuleInfo(key: "gate_proj") var gateProj: Linear
    @ModuleInfo(key: "up_proj") var upProj: Linear
    @ModuleInfo(key: "down_proj") var downProj: Linear

    init(_ config: Spark25Configuration) {
        _gateProj.wrappedValue = Linear(config.hiddenSize, config.intermediateSize, bias: config.mlpBias)
        _upProj.wrappedValue = Linear(config.hiddenSize, config.intermediateSize, bias: config.mlpBias)
        _downProj.wrappedValue = Linear(config.intermediateSize, config.hiddenSize, bias: config.mlpBias)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        // Exact (erf) GELU, as mlx.nn.gelu.
        downProj(gelu(gateProj(x)) * upProj(x))
    }
}

final class Spark25Block: Module {
    @ModuleInfo(key: "self_attn") var attention: Spark25Attention
    @ModuleInfo var mlp: Spark25MLP
    @ModuleInfo(key: "input_layernorm") var inputNorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionNorm: RMSNorm

    var isSliding: Bool {
        attention.isSliding
    }

    init(_ config: Spark25Configuration, layerIndex: Int) {
        _attention.wrappedValue = Spark25Attention(config, layerIndex: layerIndex)
        mlp = Spark25MLP(config)
        _inputNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        _postAttentionNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        super.init()
    }

    func callAsFunction(
        _ x: MLXArray, mask: MLXFast.ScaledDotProductAttentionMaskMode, cache: KVCache?
    ) -> MLXArray {
        let h = x + attention(inputNorm(x), mask: mask, cache: cache)
        return h + mlp(postAttentionNorm(h))
    }
}

final class Spark25Inner: Module {
    @ModuleInfo var embedding: Embedding
    @ModuleInfo var layers: [Spark25Block]
    @ModuleInfo var norm: RMSNorm

    let config: Spark25Configuration

    init(_ config: Spark25Configuration) {
        self.config = config
        _embedding.wrappedValue = Embedding(embeddingCount: config.vocabularySize, dimensions: config.hiddenSize)
        _layers.wrappedValue = (0 ..< config.hiddenLayers).map { Spark25Block(config, layerIndex: $0) }
        _norm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        super.init()
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        var h = embedding(inputs)
        // One mask per layer kind, read off the first cache of that kind (the
        // sliding one knows its window, the full one its offset).
        let fullMask: MLXFast.ScaledDotProductAttentionMaskMode =
            if let first = config.firstFullLayer {
                createAttentionMask(h: h, cache: cache?[first])
            } else { .none }
        let slidingMask: MLXFast.ScaledDotProductAttentionMaskMode =
            if let first = config.firstSlidingLayer {
                createAttentionMask(h: h, cache: cache?[first], windowSize: config.slidingWindow)
            } else { .none }
        for (i, layer) in layers.enumerated() {
            h = layer(h, mask: layer.isSliding ? slidingMask : fullMask, cache: cache?[i])
        }
        return norm(h)
    }
}

// MARK: - Model

public final class Spark25Model: Module, LLMModel {
    @ModuleInfo var model: Spark25Inner
    @ModuleInfo(key: "lm_head") var lmHead: Linear?

    public let config: Spark25Configuration
    public var vocabularySize: Int {
        config.vocabularySize
    }

    public init(_ config: Spark25Configuration) {
        self.config = config
        _model.wrappedValue = Spark25Inner(config)
        if !config.tieWordEmbeddings {
            _lmHead.wrappedValue = Linear(config.hiddenSize, config.vocabularySize, bias: false)
        }
        super.init()
    }

    public func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        let h = model(inputs, cache: cache)
        if let lmHead { return lmHead(h) }
        return model.embedding.asLinear(h)
    }

    /// Sliding layers get a rotating cache of the window; full layers a plain one
    /// (honouring `maxKVSize` when the caller sets it).
    public func newCache(parameters: GenerateParameters? = nil) throws -> [KVCache] {
        try (0 ..< config.hiddenLayers).map { i in
            if config.isSliding(layer: i) {
                try makeSlidingWindowKVCache(parameters: parameters, window: config.slidingWindow)
            } else {
                try makeAttentionKVCache(parameters: parameters)
            }
        }
    }

    /// Prefill through the inner model only, as Gemma3Text does: the 131,072-row tied
    /// head over every prompt position is thrown away, so skipping it is the speedup.
    /// Chunks are capped at the sliding window (an A/B `-prefillStepSize` above it would
    /// otherwise push a rotating cache past its size in one step).
    public func prepare(
        _ input: LMInput, cache: [KVCache], state _: LMOutput.State? = nil,
        prefill: PrefillParameters = .init()
    ) throws -> PrepareResult {
        let tokens = input.text
        guard tokens.tokens.dim(0) > 0 else {
            return .tokens(.init(tokens: MLXArray(Int32(0))[0 ..< 0]))
        }
        let processed = try prefill.forEachChunk(
            total: tokens.tokens.size,
            defaultStepSize: Self.defaultPrefillChunkSize,
            maximumStepSize: config.slidingWindow
        ) { range in
            _ = model(tokens[.newAxis, range].tokens, cache: cache)
            asyncEval(cache)
        }
        return .tokens(tokens[processed...])
    }

    /// Gemma3Text's tuned default; the window (512) caps it either way.
    private static let defaultPrefillChunkSize = 128

    public func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        var out: [String: MLXArray] = [:]
        out.reserveCapacity(weights.count)
        for (key, value) in weights {
            guard let kept = Self.sanitizedKey(key, tiedWordEmbeddings: config.tieWordEmbeddings) else { continue }
            // A checkpoint that has BOTH spellings keeps `model.embedding.*`.
            if out[kept] == nil || kept == key { out[kept] = value }
        }
        return out
    }

    /// The key a checkpoint tensor loads under, or nil to drop it. Pure, so the
    /// renames are testable without an MLX array: `model.embed_tokens.*` →
    /// `model.embedding.*`, `lm_head.*` dropped when the embeddings are tied, the
    /// serialised `rotary_emb.inv_freq` buffer always dropped.
    static func sanitizedKey(_ key: String, tiedWordEmbeddings: Bool) -> String? {
        if key.contains("rotary_emb.inv_freq") { return nil }
        if tiedWordEmbeddings, key.hasPrefix("lm_head.") { return nil }
        let legacy = "model.embed_tokens."
        if key.hasPrefix(legacy) { return "model.embedding." + key.dropFirst(legacy.count) }
        return key
    }

    // MARK: Registration

    /// Adds `spark2_5` to the shared LLM type registry, once. Cheap to call on
    /// every load; the provider does so before `LLMModelFactory.loadContainer`.
    public static func registerIfNeeded() async {
        // One Task for the process: a static `let` initialises once, and every caller
        // awaits the SAME completion, so a second load that races the first cannot
        // reach the factory before the registration has landed on the actor (the
        // once-flag it replaces set `done` before awaiting — pre-push review, 2026-10-21).
        await registration.value
    }

    private static let registration = Task {
        await LLMTypeRegistry.shared.registerModelType(Spark25Configuration.modelType, creator: create)
    }

    /// The registry's creator: config.json bytes → a model.
    private static func create(_ data: Data) throws -> any LanguageModel {
        let config = try JSONDecoder().decode(Spark25Configuration.self, from: data)
        return Spark25Model(config)
    }
}

extension Spark25Model: LoRAModel {
    public var loraLayers: [Module] {
        model.layers
    }
}
