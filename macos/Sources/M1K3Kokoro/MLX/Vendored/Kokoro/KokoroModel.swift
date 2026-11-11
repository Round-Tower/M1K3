//
//  KokoroModel.swift
//  M1K3Kokoro/MLX/Vendored
//
//  Vendored from Blaizzy/mlx-audio-swift (MIT), commit
//  542fffacb3be8de47024b3b54888f71d72d46d30, 2026-07-18 — LOCALLY MODIFIED.
//  See README.md ("Local modifications to KokoroModel.swift") for the full
//  rationale. Summary: dropped the `SpeechGenerationModel` conformance,
//  `textProcessor`, `tokenize`, `generate`/`generateStream`,
//  `loadVoice`/`availableVoices`/`setTextProcessor`, and the HuggingFace-Hub-
//  backed `fromPretrained` — M1K3 already owns the token pipeline
//  (`KokoroG2P`) and the voice styles (`KokoroVoices`, the historical
//  `voices-v1.0.bin`). Kept as upstream (unchanged behavior): the module
//  tree, `init`, `callAsFunction` (the forward pass), the conv-transpose
//  fixups + tensor-value half of `sanitize(weights:)`, `fromModelDirectory`
//  (minus the removed `textProcessor?.prepare()` call), `loadWeights`,
//  `quantizeTree`. ALSO locally modified: `sanitize(weights:)`'s per-key
//  string remap now delegates to `KokoroMLXWeightKeyMap.remap(_:)` (a
//  sibling, non-vendored, pure function — same rules, same order, byte-
//  identical output) so the remap is red-first unit-tested without the
//  metallib wall. ALSO (2026-11-11): `callAsFunction` throws, and its one
//  mid-pass read goes through `KokoroGuardedRead` (a tester's background
//  crash on 1.3.0; see that file).
//

import Foundation
@preconcurrency import MLX
@preconcurrency import MLXLMCommon
import MLXNN

final class KokoroModel: Module {
    let config: KokoroConfig
    let sampleRate: Int

    @ModuleInfo var bert: Albert
    @ModuleInfo(key: "bert_encoder") var bertEncoder: Linear
    @ModuleInfo var predictor: KokoroProsodyPredictor
    @ModuleInfo(key: "text_encoder") var textEncoder: KokoroTextEncoder
    @ModuleInfo var decoder: KokoroDecoder

    init(config: KokoroConfig) {
        self.config = config
        sampleRate = config.sampleRate

        _bert = ModuleInfo(wrappedValue: Albert(config: config.plbert, vocabSize: config.nToken))
        _bertEncoder = ModuleInfo(
            wrappedValue: Linear(config.plbert.hiddenSize, config.hiddenDim),
            key: "bert_encoder"
        )
        _predictor = ModuleInfo(wrappedValue: KokoroProsodyPredictor(
            styleDim: config.styleDim, dHid: config.hiddenDim,
            nLayers: config.nLayer, maxDur: config.maxDur, dropout: 0.0
        ))
        _textEncoder = ModuleInfo(wrappedValue: KokoroTextEncoder(
            channels: config.hiddenDim, kernelSize: config.textEncoderKernelSize,
            depth: config.nLayer, nSymbols: config.nToken
        ), key: "text_encoder")
        _decoder = ModuleInfo(wrappedValue: KokoroDecoder(config: config))
    }

    /// For testing: create the module tree from config without loading weights.
    static func testInit(config: KokoroConfig) -> KokoroModel {
        KokoroModel(config: config)
    }

    // MARK: - Forward Pass

    func callAsFunction(
        inputIds: MLXArray, refS: MLXArray, speed: Float = 1.0
    ) throws -> (audio: MLXArray, predDur: MLXArray) {
        let seqLen = inputIds.shape[inputIds.ndim - 1]
        let inputLengths = MLXArray([Int32(seqLen)])
        var textMask = MLXArray(Array(0 ..< Int32(seqLen))).reshaped([1, -1])
        textMask = (textMask + 1) .> inputLengths.reshaped([-1, 1])

        let attMask = MLXArray(1) - textMask.asType(.int32)
        let (bertOut, _) = bert(inputIds, attentionMask: attMask)
        let dEn = bertEncoder(bertOut).transposed(0, 2, 1)

        let globalStyle = refS[0..., 128...]
        let acousticStyle = refS[0..., ..<128]

        let d = predictor.textEncoder(dEn, style: globalStyle, textLengths: inputLengths, mask: textMask)
        let (x, _) = predictor.lstm(d)
        let duration = predictor.durationProj(x)
        // Defensive: quantized encoders may produce NaN durations for certain inputs.
        // Cap at maxFramesPerPhoneme to prevent OOM from garbage int32 casts.
        let maxFramesPerPhoneme = 100
        let durRaw = MLX.sigmoid(duration).sum(axis: -1) / speed
        let durSafe = nanToNum(durRaw, nan: 1.0)
        let predDur = MLX.clip(MLX.round(durSafe), min: 1, max: Float(maxFramesPerPhoneme))
            .asType(.int32)[0]

        // LOCAL: a guarded read, so a failed evaluation throws instead of trapping (KokoroGuardedRead).
        let durArray: [Int32] = try KokoroGuardedRead.values(predDur, as: Int32.self)
        var indices = [MLXArray]()
        for (i, n) in durArray.enumerated() {
            let count = min(max(Int(n), 0), maxFramesPerPhoneme)
            if count > 0 {
                indices.append(MLX.repeated(MLXArray(Int32(i)), count: count))
            }
        }

        // All durations collapsed to zero — return silence instead of crashing on empty concat
        guard !indices.isEmpty else {
            let silence = MLXArray.zeros([1, 1])
            return (silence, predDur)
        }
        let allIndices = MLX.concatenated(indices, axis: 0)

        let predAlnTrg = MLXArray.zeros([inputIds.shape[1], allIndices.shape[0]])
        predAlnTrg[allIndices, MLXArray(Array(0 ..< Int32(allIndices.shape[0])))] = MLXArray(Float(1))
        let predAln = predAlnTrg.expandedDimensions(axis: 0)

        let en = MLX.matmul(d.transposed(0, 2, 1), predAln)
        let (f0Pred, nPred) = predictor.predict(en, globalStyle)

        let tEn = textEncoder(inputIds, inputLengths: inputLengths, mask: textMask)
        let asr = MLX.matmul(tEn, predAln)

        let audio = decoder(asr, f0Pred, nPred, acousticStyle)
        return (audio[0], predDur)
    }

    // MARK: - Loading

    static func fromModelDirectory(_ modelDir: URL) throws -> KokoroModel {
        let configURL = modelDir.appendingPathComponent("config.json")
        let configData = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(KokoroConfig.self, from: configData)
        let model = KokoroModel(config: config)

        let weights = try loadWeights(modelDir: modelDir)
        let sanitized = model.sanitize(weights: weights)

        if let quant = config.quantization?.asTuple {
            quantizeTree(
                module: model, weights: sanitized,
                quantization: quant
            )
        }

        try model.update(parameters: ModuleParameters.unflattened(sanitized), verify: .noUnusedKeys)

        model.train(false)
        MLX.eval(model.parameters())
        return model
    }

    // MARK: - Weight Sanitization

    func sanitize(weights: [String: MLXArray]) -> [String: MLXArray] {
        let hasPackedQuantizedWeights = weights.keys.contains {
            $0.hasSuffix(".scales") || $0.hasSuffix(".biases")
        }
        let needsConvTranspose = !hasPackedQuantizedWeights

        var result = [String: MLXArray]()
        for (k, v) in weights {
            // LOCAL MODIFICATION (2026-07-18): the string-only key remap now lives
            // in KokoroMLXWeightKeyMap.remap(_:) — same rules, same order, byte-
            // identical output — so it can be red-first unit-tested without the
            // metallib wall (MLXArray values never enter that function). See
            // README.md's "Local modifications" section.
            guard let nk = KokoroMLXWeightKeyMap.remap(k) else { continue }

            var value = v
            if needsConvTranspose {
                if nk.contains("F0_proj.weight") || nk.contains("N_proj.weight"), v.ndim == 3 {
                    value = v.transposed(0, 2, 1)
                } else if nk.contains("noise_convs"), nk.hasSuffix(".weight"), v.ndim == 3 {
                    value = v.transposed(0, 2, 1)
                } else if nk.hasSuffix("weight_v"), v.ndim == 3 {
                    let (o, h, w) = (v.shape[0], v.shape[1], v.shape[2])
                    if !(o >= h && o >= w && h == w) {
                        value = v.transposed(0, 2, 1)
                    }
                }
            }

            result[nk] = value
        }
        return result
    }

    // MARK: - Weight Loading

    private static func loadWeights(modelDir: URL) throws -> [String: MLXArray] {
        let url = modelDir.appendingPathComponent("model.safetensors")
        if FileManager.default.fileExists(atPath: url.path) {
            return try MLX.loadArrays(url: url)
        }
        var allWeights = [String: MLXArray]()
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(at: modelDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "safetensors"
                && !$0.lastPathComponent.contains("voices")
            }
        for file in files {
            for (k, v) in try MLX.loadArrays(url: file) {
                allWeights[k] = v
            }
        }
        return allWeights
    }

    // MARK: - Tree-Walking Quantization

    private static func quantizeTree(
        module: Module,
        weights: [String: MLXArray],
        quantization: (groupSize: Int, bits: Int, mode: QuantizationMode),
        path: String = ""
    ) {
        var replacements = [(String, Module)]()

        for (key, child) in module.items() {
            let childPath = path.isEmpty ? key : "\(path).\(key)"

            switch child {
            case let .value(.module(childModule)):
                if childModule is Quantizable,
                   weights["\(childPath).scales"] != nil,
                   let quantized = quantizeSingle(
                       layer: childModule,
                       groupSize: quantization.groupSize,
                       bits: quantization.bits,
                       mode: quantization.mode
                   )
                {
                    replacements.append((key, quantized))
                } else {
                    quantizeTree(
                        module: childModule, weights: weights,
                        quantization: quantization, path: childPath
                    )
                }

            case let .array(items):
                for (index, item) in items.enumerated() {
                    let indexPath = "\(childPath).\(index)"
                    switch item {
                    case let .value(.module(childModule)):
                        quantizeTree(
                            module: childModule, weights: weights,
                            quantization: quantization, path: indexPath
                        )
                    case let .array(nestedItems):
                        for (nestedIndex, nestedItem) in nestedItems.enumerated() {
                            if case let .value(.module(nestedModule)) = nestedItem {
                                quantizeTree(
                                    module: nestedModule, weights: weights,
                                    quantization: quantization,
                                    path: "\(indexPath).\(nestedIndex)"
                                )
                            }
                        }
                    default:
                        break
                    }
                }

            default:
                break
            }
        }

        if !replacements.isEmpty {
            module.update(modules: ModuleChildren.unflattened(replacements))
        }
    }
}
