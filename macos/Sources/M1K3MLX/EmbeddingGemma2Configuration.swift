//
//  EmbeddingGemma2Configuration.swift
//  M1K3MLX
//
//  The text-core fields of EmbeddingGemma 2's config.json (see EmbeddingGemma2.swift
//  for the model and its provenance). Split out for file length only.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-10, Confidence 0.85, Prior: none (new file).

import Foundation

// MARK: - Configuration

/// The text-core fields of `config.json`, nested under `text_config` in the
/// multimodal checkpoint or at the top level in a text-only one.
public struct EmbeddingGemma2Configuration: Decodable, Sendable {
    /// Per-layer attention layout: global layers override the head width and
    /// KV-head count (`per_layer_config`) and use the global rope base.
    public struct Layer: Equatable, Sendable {
        public let headDim: Int
        public let kvHeads: Int
        public let ropeBase: Float
        public let isGlobal: Bool
    }

    public let hiddenSize: Int
    public let hiddenLayers: Int
    public let attentionHeads: Int
    public let intermediateSize: Int
    public let perLayerInputSize: Int
    public let embeddingDim: Int
    public let vocabularySize: Int
    public let rmsNormEps: Float
    /// Radius: a token attends to keys within this distance on either side.
    public let slidingWindow: Int
    public let padTokenID: Int
    public let layers: [Layer]

    private struct Override: Decodable {
        let headDim: Int?
        let numKeyValueHeads: Int?

        enum CodingKeys: String, CodingKey {
            case headDim = "head_dim"
            case numKeyValueHeads = "num_key_value_heads"
        }
    }

    private struct Rope: Decodable {
        let ropeTheta: Float

        enum CodingKeys: String, CodingKey {
            case ropeTheta = "rope_theta"
        }
    }

    private struct Text: Decodable {
        let hiddenSize: Int
        let numHiddenLayers: Int
        let numAttentionHeads: Int
        let numKeyValueHeads: Int
        let headDim: Int
        let intermediateSize: Int
        let hiddenSizePerLayerInput: Int
        let embeddingDim: Int
        let vocabSize: Int
        let rmsNormEps: Float
        let slidingWindow: Int
        let padTokenID: Int?
        let layerTypes: [String]
        let perLayerConfig: [String: Override]?
        let ropeParameters: [String: Rope]

        enum CodingKeys: String, CodingKey {
            case hiddenSize = "hidden_size"
            case numHiddenLayers = "num_hidden_layers"
            case numAttentionHeads = "num_attention_heads"
            case numKeyValueHeads = "num_key_value_heads"
            case headDim = "head_dim"
            case intermediateSize = "intermediate_size"
            case hiddenSizePerLayerInput = "hidden_size_per_layer_input"
            case embeddingDim = "embedding_dim"
            case vocabSize = "vocab_size"
            case rmsNormEps = "rms_norm_eps"
            case slidingWindow = "sliding_window"
            case padTokenID = "pad_token_id"
            case layerTypes = "layer_types"
            case perLayerConfig = "per_layer_config"
            case ropeParameters = "rope_parameters"
        }
    }

    private enum RootKeys: String, CodingKey {
        case modelType = "model_type"
        case textConfig = "text_config"
    }

    public init(from decoder: any Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)
        let modelType = try root.decodeIfPresent(String.self, forKey: .modelType)
        guard modelType == nil || EmbeddingGemma2TextModel.modelTypes.contains(modelType!) else {
            throw DecodingError.dataCorruptedError(
                forKey: .modelType, in: root,
                debugDescription: "not an EmbeddingGemma 2 checkpoint: model_type \(modelType ?? "nil")"
            )
        }
        let text = try root.decodeIfPresent(Text.self, forKey: .textConfig) ?? Text(from: decoder)
        guard text.layerTypes.count == text.numHiddenLayers else {
            throw DecodingError.dataCorruptedError(
                forKey: .textConfig, in: root,
                debugDescription: "layer_types has \(text.layerTypes.count) entries for \(text.numHiddenLayers) layers"
            )
        }
        // HF serialises `per_layer_config` keys as integers ("5"); mlx-vlm's
        // conversions zero-pad them ("05"). Both are live on the Hub.
        var overrides: [Int: Override] = [:]
        for (key, value) in text.perLayerConfig ?? [:] {
            guard let layer = Int(key) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .textConfig, in: root, debugDescription: "per_layer_config key \(key) is not a layer index"
                )
            }
            overrides[layer] = value
        }
        var layers: [Layer] = []
        for (index, type) in text.layerTypes.enumerated() {
            guard let rope = text.ropeParameters[type] else {
                throw DecodingError.dataCorruptedError(
                    forKey: .textConfig, in: root, debugDescription: "no rope_parameters for \(type)"
                )
            }
            let override = overrides[index]
            layers.append(Layer(
                headDim: override?.headDim ?? text.headDim,
                kvHeads: override?.numKeyValueHeads ?? text.numKeyValueHeads,
                ropeBase: rope.ropeTheta,
                isGlobal: type == "full_attention"
            ))
        }
        hiddenSize = text.hiddenSize
        hiddenLayers = text.numHiddenLayers
        attentionHeads = text.numAttentionHeads
        intermediateSize = text.intermediateSize
        perLayerInputSize = text.hiddenSizePerLayerInput
        embeddingDim = text.embeddingDim
        vocabularySize = text.vocabSize
        rmsNormEps = text.rmsNormEps
        slidingWindow = text.slidingWindow
        padTokenID = text.padTokenID ?? 0
        self.layers = layers
    }
}

public enum EmbeddingGemma2Error: Error, Equatable {
    case notEmbeddingGemma2(String)
}
