//
//  EmbeddingGemma2.swift
//  M1K3MLX
//
//  EmbeddingGemma 2's text core (`google/embeddinggemma-2`, `model_type:
//  embedding_gemma2`) as an MLXEmbedders model: 24 bidirectional Gemma-4-style
//  layers with projection-only per-layer embeddings, mean pooling, a 512 → 768
//  projection, then L2 normalisation. The vision and audio encoders in the same
//  checkpoint are dropped at load — this is the retrieval embedder for text and
//  code; multimodal memory (Stream D) adds the encoders later.
//
//  Why our own file: mlx-swift-lm at our pin (3.32.3) has no Gemma-4-based
//  embedder (MLXEmbedders: Bert / Gemma3 / LFM2 / NomicBert / Qwen3), and the
//  upstream PR that adds one (ml-explore/mlx-swift-lm#684, 2026-10-09) is a
//  3.5k-line unreviewed refactor of MLXVLM's Gemma4. The text core is ~200
//  lines of Python in mlx-vlm (the implementation mlx-community validated the
//  8-bit conversion with), so it is ported from that (~500 lines of Swift
//  with the configuration and the embedder), and checked against its
//  vectors (Tests/M1K3MLXTests/Fixtures/embeddinggemma2-reference.json) by
//  EmbeddingGemma2RefStage inside the app.
//
//  Shape notes that are easy to get wrong:
//  - Token embeddings are scaled by sqrt(hidden) rounded to the weight dtype
//    (22.625 in bf16), and the PLE projection reads the SCALED embeddings.
//  - Attention scale is 1.0: q/k RMSNorms carry the scaling; v is RMS-normed
//    with no learned weight.
//  - Global layers (every sixth) use one 512-wide KV head on the 1M rope;
//    sliding layers 2×256 on 10k with a ±512 window (both sides — bidirectional).
//  - RMSNorm weights scale directly (Gemma 4), not `1 + w` (Gemma 3).
//
//  Signed: Kev + claude-fable-5.1, 2026-10-10, Confidence 0.8, Prior: none (new
//  file; GEMMA_1_1_PLAN Stream C slice 2). Port of mlx-vlm 3d87e884's
//  `embedding_gemma2/language.py`; structure cross-read against upstream #684.
//  Open: numeric parity is proven by the in-app reference stage, not here;
//  the whole 1.2 GB checkpoint is read before the encoders are dropped (a
//  text-only split is a follow-up).
//  Review: Kev + claude-fable-5.1, 2026-10-10 (#545 bot pass) — the sliding mask is now covered by a
//  1,396-token fixture case (cosine 0.99996); `loadWeights` takes the per-layer quantization only.
//  Review: Kev + claude-fable-5.1, 2026-10-10 (#545 pass 2) — an empty id sequence yields no vector.

import Foundation
import MLX
import MLXEmbedders
import MLXFast
import MLXLMCommon
import MLXNN

// MARK: - Model

/// The text core as a `BaseLanguageModel` (so `MLXLMCommon.loadWeights` handles
/// the quantised layers): `[B, L]` tokens → `[B, L, embeddingDim]` projected
/// states. `EmbeddingGemma2Embedder` pools and normalises. It does NOT conform to
/// MLXEmbedders' `EmbeddingModel`: that protocol's output type has no public
/// initialiser, so a model outside the upstream module cannot produce one.
public final class EmbeddingGemma2TextModel: Module, BaseLanguageModel {
    /// Both spellings the checkpoints use.
    public static let modelTypes = ["embedding_gemma2", "embedding_gemma2_text"]

    /// The model card's context window. `max_position_embeddings` (262,144)
    /// is the rope table, not a usable length: head widths 256 and 512 fall
    /// outside mlx's fused attention kernel, so a long input materialises
    /// `[heads, L, L]` scores per layer. Inputs are cut here, keeping `<eos>`.
    public static let contextLength = 8192

    public let config: EmbeddingGemma2Configuration

    @ModuleInfo(key: "language_model") var languageModel: EmbeddingGemma2TextCore

    public init(_ config: EmbeddingGemma2Configuration) {
        self.config = config
        _languageModel.wrappedValue = EmbeddingGemma2TextCore(config)
        super.init()
    }

    /// `[B, L]` tokens (+ optional `[B, L]` 1/0 mask) → `[B, L, embeddingDim]`.
    public func callAsFunction(_ tokens: MLXArray, attentionMask: MLXArray? = nil) -> MLXArray {
        languageModel(tokens, attentionMask: attentionMask)
    }

    /// Keeps the text core and drops the vision/audio encoders. A text-only
    /// checkpoint stores the same tensors without the `language_model.` prefix.
    public func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        var kept: [String: MLXArray] = [:]
        for (key, value) in weights {
            if let textKey = Self.textCoreKey(key) { kept[textKey] = value }
        }
        return kept
    }

    /// The text-core parameter path for a checkpoint key, or nil for an
    /// encoder tensor. Pure, so the filter is unit-tested without MLX.
    static func textCoreKey(_ key: String) -> String? {
        var key = key
        if key.hasPrefix("model.") { key.removeFirst("model.".count) }
        if key.hasPrefix("language_model.") { return key }
        let textPrefixes = ["embed_tokens.", "embedding_projection.", "ple.", "layers.", "norm."]
        if textPrefixes.contains(where: key.hasPrefix) { return "language_model." + key }
        return nil
    }

    /// Every parameter path the module declares for `config`, as the 8-bit
    /// checkpoint names them (quantised Linear/Embedding carry weight + scales +
    /// biases; norms and `layer_scalar` a bare weight). Pure: pinned against the
    /// checkpoint's weight index by EmbeddingGemma2Tests.
    static func weightKeys(for config: EmbeddingGemma2Configuration) -> [String] {
        func quantised(_ path: String) -> [String] {
            ["weight", "scales", "biases"].map { "\(path).\($0)" }
        }
        var keys = quantised("language_model.embed_tokens")
        keys += quantised("language_model.embedding_projection")
        keys += quantised("language_model.ple.per_layer_model_projection")
        keys += ["language_model.ple.per_layer_projection_norm.weight", "language_model.norm.weight"]
        for index in 0 ..< config.hiddenLayers {
            let layer = "language_model.layers.\(index)"
            keys += ["\(layer).input_layernorm.weight", "\(layer).layer_scalar"]
            for projection in ["down_proj", "gate_proj", "up_proj"] {
                keys += quantised("\(layer).mlp.\(projection)")
            }
            for projection in ["per_layer_input_gate", "per_layer_projection"] {
                keys += quantised("\(layer).ple_block.\(projection)")
            }
            keys += [
                "\(layer).ple_block.post_per_layer_input_norm.weight",
                "\(layer).post_attention_layernorm.weight",
                "\(layer).post_feedforward_layernorm.weight",
                "\(layer).pre_feedforward_layernorm.weight",
                "\(layer).self_attn.k_norm.weight",
                "\(layer).self_attn.q_norm.weight",
            ]
            for projection in ["k_proj", "o_proj", "q_proj", "v_proj"] {
                keys += quantised("\(layer).self_attn.\(projection)")
            }
        }
        return keys
    }
}

// MARK: - Embedder

/// A loaded EmbeddingGemma 2 text core with its tokenizer: the sentence-
/// transformers pipeline (prompted text → `<bos>…<eos>` → mean over tokens →
/// L2 norm) as one actor, so model access is isolated the way MLXEmbedders'
/// container isolates its models.
public actor EmbeddingGemma2Embedder {
    private let model: EmbeddingGemma2TextModel
    private let tokenizer: any MLXLMCommon.Tokenizer

    public nonisolated let embeddingDim: Int

    init(model: EmbeddingGemma2TextModel, tokenizer: any MLXLMCommon.Tokenizer) {
        self.model = model
        self.tokenizer = tokenizer
        embeddingDim = model.config.embeddingDim
    }

    /// Resolves `configuration` (a Hub id downloads through `downloader`; a
    /// directory loads in place), reads `config.json`, loads the text core
    /// (quantised per the checkpoint's `quantization` block) and the tokenizer.
    public static func load(
        configuration: ModelConfiguration,
        from downloader: any Downloader,
        tokenizerLoader: any TokenizerLoader,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> EmbeddingGemma2Embedder {
        let resolved = try await resolve(
            configuration: configuration, from: downloader, useLatest: false, progressHandler: progressHandler
        )
        let configData = try Data(contentsOf: resolved.modelDirectory.appending(component: "config.json"))
        let base = try JSONDecoder.json5().decode(BaseConfiguration.self, from: configData)
        guard EmbeddingGemma2TextModel.modelTypes.contains(base.modelType) else {
            throw EmbeddingGemma2Error.notEmbeddingGemma2(base.modelType)
        }
        let config = try JSONDecoder.json5().decode(EmbeddingGemma2Configuration.self, from: configData)
        let model = EmbeddingGemma2TextModel(config)
        async let tokenizer = tokenizerLoader.load(from: resolved.tokenizerDirectory)
        // `perLayerQuantization` carries the checkpoint's `quantization` block too.
        try await loadWeights(
            modelDirectory: resolved.modelDirectory, model: model, perLayerQuantization: base.perLayerQuantization
        )
        return try await EmbeddingGemma2Embedder(model: model, tokenizer: tokenizer)
    }

    /// The token ids `text` embeds as (the tokenizer's post-processor adds
    /// `<bos>` and `<eos>`). Exposed for the reference stage.
    public func tokenize(_ text: String) -> [Int] {
        tokenizer.encode(text: text)
    }

    /// The unit-length `embeddingDim` vector for `text`, taken exactly as given.
    /// Inputs past `contextLength` tokens are cut, keeping the closing `<eos>`.
    public func embed(_ text: String) -> [Float] {
        let ids = Self.capped(tokenize(text), to: EmbeddingGemma2TextModel.contextLength)
        // The post-processor always adds <bos>/<eos>; an empty sequence would
        // mean-pool to NaN, so it returns no vector and the service's width
        // check throws instead of storing garbage.
        guard !ids.isEmpty else { return [] }
        let tokens = MLXArray(ids.map { Int32($0) }).expandedDimensions(axis: 0)
        let states = model(tokens).asType(.float32)
        let pooled = states.mean(axis: 1).squeezed(axis: 0)
        let norm = maximum(sqrt((pooled * pooled).sum()), MLXArray(Float(1e-9)))
        let vector = pooled / norm
        eval(vector)
        return vector.asArray(Float.self)
    }
}

extension EmbeddingGemma2Embedder {
    /// `ids` cut to `limit` tokens with the last one (the tokenizer's `<eos>`)
    /// kept, so a truncated document still ends the way the model was trained on.
    static func capped(_ ids: [Int], to limit: Int) -> [Int] {
        guard ids.count > limit, let last = ids.last else { return ids }
        return Array(ids.prefix(limit - 1)) + [last]
    }
}

// MARK: - Text core

final class EmbeddingGemma2TextCore: Module {
    @ModuleInfo(key: "embed_tokens") var embedTokens: Embedding
    @ModuleInfo(key: "ple") var ple: EmbeddingGemma2PerLayerInputs
    @ModuleInfo(key: "layers") var layers: [EmbeddingGemma2Layer]
    @ModuleInfo(key: "norm") var norm: RMSNorm
    @ModuleInfo(key: "embedding_projection") var embeddingProjection: Linear

    private let hiddenSize: Int
    private let slidingWindow: Int

    init(_ config: EmbeddingGemma2Configuration) {
        hiddenSize = config.hiddenSize
        slidingWindow = config.slidingWindow
        _embedTokens.wrappedValue = Embedding(embeddingCount: config.vocabularySize, dimensions: config.hiddenSize)
        _ple.wrappedValue = EmbeddingGemma2PerLayerInputs(config)
        _layers.wrappedValue = config.layers.map { EmbeddingGemma2Layer(config, layer: $0) }
        _norm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        _embeddingProjection.wrappedValue = Linear(config.hiddenSize, config.embeddingDim, bias: false)
        super.init()
    }

    /// `[B, L]` tokens (+ optional `[B, L]` 1/0 mask) → `[B, L, embeddingDim]`.
    func callAsFunction(_ tokens: MLXArray, attentionMask: MLXArray?) -> MLXArray {
        var hidden = embedTokens(tokens)
        // The model card forbids float16 (activations exceed its range); a
        // float16 conversion would overflow silently into degenerate vectors.
        if hidden.dtype == .float16 { hidden = hidden.asType(.float32) }
        // The reference rounds sqrt(hidden) to the activation dtype (22.625 in bf16).
        hidden *= MLXArray(Float(hiddenSize).squareRoot()).asType(hidden.dtype)
        let perLayerInputs = ple(hidden)

        let length = tokens.dim(1)
        let (globalMask, localMask) = Self.masks(length: length, window: slidingWindow, attentionMask: attentionMask)
        for (index, layer) in layers.enumerated() {
            hidden = layer(
                hidden,
                perLayerInput: perLayerInputs[0..., 0..., index, 0...],
                mask: layer.isGlobal ? globalMask : localMask
            )
        }
        return embeddingProjection(norm(hidden))
    }

    /// Boolean `[B, 1, L, L]` (or `[B, 1, 1, L]`) masks for the global and the
    /// sliding layers; nil where every key is visible. Bidirectional: the window
    /// is `|i - j| <= window`, both sides.
    static func masks(length: Int, window: Int, attentionMask: MLXArray?) -> (global: MLXArray?, local: MLXArray?) {
        let padding = attentionMask.map { ($0 .> 0).reshaped($0.dim(0), 1, 1, length) }
        guard length - 1 > window else { return (padding, padding) }
        let positions = MLXArray(Int32(0) ..< Int32(length))
        let distance = abs(positions.reshaped(length, 1) - positions.reshaped(1, length))
        var local = (distance .<= Int32(window)).reshaped(1, 1, length, length)
        if let padding { local = local .&& padding }
        return (padding, local)
    }
}

/// Per-layer embeddings derived from the scaled token embeddings alone
/// (EmbeddingGemma 2 has no per-layer embedding table): `[B, L, layers, width]`.
final class EmbeddingGemma2PerLayerInputs: Module {
    @ModuleInfo(key: "per_layer_model_projection") var projection: Linear
    @ModuleInfo(key: "per_layer_projection_norm") var norm: RMSNorm

    private let layerCount: Int
    private let width: Int
    private let scale: Float

    init(_ config: EmbeddingGemma2Configuration) {
        layerCount = config.hiddenLayers
        width = config.perLayerInputSize
        scale = 1 / Float(config.hiddenSize).squareRoot()
        _projection.wrappedValue = Linear(
            config.hiddenSize, config.hiddenLayers * config.perLayerInputSize, bias: false
        )
        _norm.wrappedValue = RMSNorm(dimensions: config.perLayerInputSize, eps: config.rmsNormEps)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let projected = projection(x) * scale
        return norm(projected.reshaped(x.dim(0), x.dim(1), layerCount, width))
    }
}

final class EmbeddingGemma2Layer: Module {
    @ModuleInfo(key: "self_attn") var attention: EmbeddingGemma2Attention
    @ModuleInfo(key: "mlp") var mlp: EmbeddingGemma2MLP
    @ModuleInfo(key: "ple_block") var pleBlock: EmbeddingGemma2PerLayerBlock
    @ModuleInfo(key: "input_layernorm") var inputNorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postAttentionNorm: RMSNorm
    @ModuleInfo(key: "pre_feedforward_layernorm") var preFeedforwardNorm: RMSNorm
    @ModuleInfo(key: "post_feedforward_layernorm") var postFeedforwardNorm: RMSNorm
    @ParameterInfo(key: "layer_scalar") var layerScalar: MLXArray

    let isGlobal: Bool

    init(_ config: EmbeddingGemma2Configuration, layer: EmbeddingGemma2Configuration.Layer) {
        isGlobal = layer.isGlobal
        _attention.wrappedValue = EmbeddingGemma2Attention(config, layer: layer)
        _mlp.wrappedValue = EmbeddingGemma2MLP(config)
        _pleBlock.wrappedValue = EmbeddingGemma2PerLayerBlock(config)
        _inputNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        _postAttentionNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        _preFeedforwardNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        _postFeedforwardNorm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        _layerScalar.wrappedValue = MLXArray.ones([1])
        super.init()
    }

    func callAsFunction(_ x: MLXArray, perLayerInput: MLXArray, mask: MLXArray?) -> MLXArray {
        var hidden = x + postAttentionNorm(attention(inputNorm(x), mask: mask))
        hidden += postFeedforwardNorm(mlp(preFeedforwardNorm(hidden)))
        return pleBlock(hidden, perLayerInput: perLayerInput) * layerScalar
    }
}

final class EmbeddingGemma2Attention: Module {
    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "o_proj") var oProj: Linear
    @ModuleInfo(key: "q_norm") var qNorm: RMSNorm
    @ModuleInfo(key: "k_norm") var kNorm: RMSNorm

    private let heads: Int
    private let kvHeads: Int
    private let headDim: Int
    private let eps: Float
    private let rope: RoPE

    init(_ config: EmbeddingGemma2Configuration, layer: EmbeddingGemma2Configuration.Layer) {
        heads = config.attentionHeads
        kvHeads = layer.kvHeads
        headDim = layer.headDim
        eps = config.rmsNormEps
        rope = RoPE(dimensions: layer.headDim, traditional: false, base: layer.ropeBase)
        _qProj.wrappedValue = Linear(config.hiddenSize, heads * headDim, bias: false)
        _kProj.wrappedValue = Linear(config.hiddenSize, kvHeads * headDim, bias: false)
        _vProj.wrappedValue = Linear(config.hiddenSize, kvHeads * headDim, bias: false)
        _oProj.wrappedValue = Linear(heads * headDim, config.hiddenSize, bias: false)
        _qNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: config.rmsNormEps)
        _kNorm.wrappedValue = RMSNorm(dimensions: headDim, eps: config.rmsNormEps)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, mask: MLXArray?) -> MLXArray {
        let (batch, length) = (x.dim(0), x.dim(1))
        let q = rope(qNorm(qProj(x).reshaped(batch, length, heads, headDim)).transposed(0, 2, 1, 3))
        let k = rope(kNorm(kProj(x).reshaped(batch, length, kvHeads, headDim)).transposed(0, 2, 1, 3))
        let rawValues = vProj(x).reshaped(batch, length, kvHeads, headDim)
        // v is RMS-normed with no learned scale; q/k norms replace 1/sqrt(d), so scale is 1.
        let unit = MLXArray.ones([headDim]).asType(rawValues.dtype)
        let v = MLXFast.rmsNorm(rawValues, weight: unit, eps: eps).transposed(0, 2, 1, 3)
        let output = MLXFast.scaledDotProductAttention(queries: q, keys: k, values: v, scale: 1, mask: mask)
        return oProj(output.transposed(0, 2, 1, 3).reshaped(batch, length, -1))
    }
}

final class EmbeddingGemma2MLP: Module {
    @ModuleInfo(key: "gate_proj") var gateProj: Linear
    @ModuleInfo(key: "up_proj") var upProj: Linear
    @ModuleInfo(key: "down_proj") var downProj: Linear

    init(_ config: EmbeddingGemma2Configuration) {
        _gateProj.wrappedValue = Linear(config.hiddenSize, config.intermediateSize, bias: false)
        _upProj.wrappedValue = Linear(config.hiddenSize, config.intermediateSize, bias: false)
        _downProj.wrappedValue = Linear(config.intermediateSize, config.hiddenSize, bias: false)
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        downProj(geluApproximate(gateProj(x)) * upProj(x))
    }
}

/// Gates the residual stream with this layer's slice of the per-layer inputs.
final class EmbeddingGemma2PerLayerBlock: Module {
    @ModuleInfo(key: "per_layer_input_gate") var gate: Linear
    @ModuleInfo(key: "per_layer_projection") var projection: Linear
    @ModuleInfo(key: "post_per_layer_input_norm") var norm: RMSNorm

    init(_ config: EmbeddingGemma2Configuration) {
        _gate.wrappedValue = Linear(config.hiddenSize, config.perLayerInputSize, bias: false)
        _projection.wrappedValue = Linear(config.perLayerInputSize, config.hiddenSize, bias: false)
        _norm.wrappedValue = RMSNorm(dimensions: config.hiddenSize, eps: config.rmsNormEps)
        super.init()
    }

    func callAsFunction(_ x: MLXArray, perLayerInput: MLXArray) -> MLXArray {
        let gated = geluApproximate(gate(x)) * perLayerInput
        return x + norm(projection(gated))
    }
}
