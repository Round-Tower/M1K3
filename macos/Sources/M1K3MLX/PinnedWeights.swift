//
//  PinnedWeights.swift
//  M1K3MLX
//
//  GENERATED — do not hand-edit. Regenerate with:
//      python3 macos/tools/weights/pin_weights.py
//
//  The manifest WeightIntegrity checks downloaded weights against. It
//  lives in our source, under review, on purpose: fetching the expected
//  digest from the same host that serves the file proves nothing, since
//  whoever can swap the file can swap its published hash too.
//
//  Each digest was computed from a local snapshot that had been run and
//  evaluated, then cross-checked against HuggingFace's published LFS oid
//  where one exists. The generator hard-stops on any disagreement.
//
//  Changing a pin is a deliberate act: it means shipping different
//  weights, and it should be reviewed like any other behaviour change.
//

import Foundation

/// The shipped weight manifest. Repos absent from this table load
/// unverified by design — see `WeightIntegrity.Verdict.unpinned`.
public enum PinnedWeights {
    public static let all: [String: WeightIntegrity.Pin] = [
        "mlx-community/LFM2.5-1.2B-Instruct-4bit": .init(
            revision: "dee2f8a2786e6648bb644a7ca40652842490034b",
            files: [
                "chat_template.jinja": .init(size: 1836, sha256: "3acb41f339d069a43037e6b9a9715cbeece8874eb25a7cabf1a33903d7724d6d"),
                "config.json": .init(size: 1572, sha256: "3201758c1b68e92a8102583626b0d76f70ff4c6fc2e2b99d32e96cdbe6788cea"),
                "generation_config.json": .init(size: 132, sha256: "5ffd97da1dec4308543894569662d96e923ed01f7a9d8c7ff5aea7f800738cbd"),
                "model.safetensors": .init(size: 658_540_250, sha256: "d837f243744bbdbe7dd032f90b482a1c45d5b6035b25c1d7804d0f4c74b5c004"),
                "model.safetensors.index.json": .init(size: 23414, sha256: "3074009e9be56358bf8edc25354572cbca2b5a625e02f8a2c2789a656f51f5a1"),
                "special_tokens_map.json": .init(size: 434, sha256: "742aefe2b7dec496e8caffdba03a75d0c1a9925d53bd3f3e0d388c96b591b6f4"),
                "tokenizer.json": .init(size: 4_733_389, sha256: "df1d8d5ec5d091b460562ffd545e4a5e91d17d4a0db7ebe733be34ed374377bd"),
                "tokenizer_config.json": .init(size: 92225, sha256: "2a52ec012d3df831ba434b081bef3726a6ee22501f062ad8353c557a0cfa0d01"),
            ]
        ),
        "mlx-community/Qwen3-4B-Instruct-2507-4bit-DWQ-2510": .init(
            revision: "c073725c8ac051eabad9d64f4dcd3019d1072559",
            files: [
                "added_tokens.json": .init(size: 707, sha256: "c0284b582e14987fbd3d5a2cb2bd139084371ed9acbae488829a1c900833c680"),
                "chat_template.jinja": .init(size: 2630, sha256: "64f85b198065d0fba2a81f37e10ed68161ce2c19a754c7100e67e0ca2ee9c326"),
                "config.json": .init(size: 990, sha256: "387b98441ee36d609cb2657646fb8ab7cedaecbff1c83422e4d4a61b4f49e8a3"),
                "generation_config.json": .init(size: 238, sha256: "835fffe355c9438e7a25be099b3fccaa98350b83451f9fd2d99512e74f1ade48"),
                "model.safetensors": .init(size: 2_263_022_417, sha256: "bf7129c6518c5743080e687855a6ae4a4fb307de5d6239a18527d270dd960f69"),
                "model.safetensors.index.json": .init(size: 63964, sha256: "388d811b8b7c2608dd04cce1bcb04a8bf715d19b42790894e6d3427ff429a777"),
                "special_tokens_map.json": .init(size: 613, sha256: "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd"),
                "tokenizer.json": .init(size: 11_422_654, sha256: "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
                "tokenizer_config.json": .init(size: 5405, sha256: "4b5f2f80f84faefe8420e1616671adb1dd3d7e632038d34b1f0e3a1363a51059"),
                "vocab.json": .init(size: 2_776_833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
            ]
        ),
        "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ": .init(
            revision: "6c3ae70858513f1a78e9cdca3cae330d9075cd2a",
            files: [
                "added_tokens.json": .init(size: 707, sha256: "c0284b582e14987fbd3d5a2cb2bd139084371ed9acbae488829a1c900833c680"),
                "chat_template.jinja": .init(size: 4116, sha256: "87a2728cb8dc9fe424d624542f6060ec05a1d285ebbec578bb078900e33396b5"),
                "config.json": .init(size: 937, sha256: "e7dfa5b73fb2a03cbc8fb40c394e95b99f03348e237f7f28e7a1daf56a2169bb"),
                "generation_config.json": .init(size: 117, sha256: "28396d421a2108acce96383f6a7de78008f7f1b17f807958f3c14c51dbfb65fb"),
                "model.safetensors": .init(size: 335_296_756, sha256: "3d773d5ee582eda445daeee23f7a2b76124011796df244ddb45e22638fdb7cde"),
                "model.safetensors.index.json": .init(size: 49770, sha256: "90d82744cdb6b7d093f0b812fc21a49b6ffa9d0084a45428f0cfd01eb4adbe12"),
                "special_tokens_map.json": .init(size: 613, sha256: "76862e765266b85aa9459767e33cbaf13970f327a0e88d1c65846c2ddd3a1ecd"),
                "tokenizer.json": .init(size: 11_423_705, sha256: "def76fb086971c7867b829c23a26261e38d9d74e02139253b38aeb9df8b4b50a"),
                "tokenizer_config.json": .init(size: 5404, sha256: "443bfa629eb16387a12edbf92a76f6a6f10b2af3b53d87ba1550adfcf45f7fa0"),
                "vocab.json": .init(size: 2_776_833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
            ]
        ),
        "mlx-community/gemma-4-12B-it-4bit": .init(
            revision: "73bcf09092aa277861d5a191b989b666f7f32e8f",
            files: [
                // NOT the snapshot's template: Gemma4TemplateFix installs
                // Google's 2026-07-09 canonical over the stale 2026-06-03 one
                // BEFORE the scan runs, so the manifest pins the healed bytes
                // (vendored resource, sha re-verified on every read).
                "chat_template.jinja": .init(size: 18683, sha256: "ae53464bf3be25802b3a5b37def7fd89667067d7577049b3b2d74c4d8de4c6d4"),
                "config.json": .init(size: 5415, sha256: "fbc1c1cb48ed86ec98482b2d41f5a03d3991aba74b7c29a93d430761e6518a38"),
                "generation_config.json": .init(size: 260, sha256: "a8349d9bd64cc5841297fcb5002f0fdc4749c473c8f1b10ea337f9ce4ee7014e"),
                "model-00001-of-00002.safetensors": .init(size: 5_351_756_584, sha256: "0d58feed0c98a69c07317b4481aeae5ab2785f12a496ea96ab24c4842808de78"),
                "model-00002-of-00002.safetensors": .init(size: 1_389_282_927, sha256: "5b00a1bcb596ce6e827b4cdea6ecf2a0f35bb01306eb87c1ea4b3bcde36c7755"),
                "model.safetensors.index.json": .init(size: 135_329, sha256: "9ac99e7a6cf3e4d40eb8df01644fe9c04036ace94f3389df35db9d9449758516"),
                "processor_config.json": .init(size: 868, sha256: "016a1db9c4f41ea0c61919c46855ea5e7c45c6e4ae4bfbedfb5b6bed79a2fe92"),
                "tokenizer.json": .init(size: 32_169_626, sha256: "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f"),
                "tokenizer_config.json": .init(size: 2719, sha256: "fc1384a911d2c9860ac07bc3ceafff20bff26695991744b7dbe5e1e4522bfa57"),
            ]
        ),
    ]

    /// Which download root each pinned repo belongs under. LLM weights
    /// and embedder weights live in genuinely different places (the 2.x
    /// layout, preserved so existing caches keep working), so anything
    /// installing files has to know which — assuming one base puts the
    /// embedder where its loader never looks.
    public static let bases: [String: WeightIntegrity.DownloadBase] = [
        "mlx-community/LFM2.5-1.2B-Instruct-4bit": .llm,
        "mlx-community/Qwen3-4B-Instruct-2507-4bit-DWQ-2510": .llm,
        "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ": .embedder,
        "mlx-community/gemma-4-12B-it-4bit": .llm,
    ]

    /// The pin for `repoID`, or nil when the repo ships unpinned.
    public static func pin(for repoID: String) -> WeightIntegrity.Pin? {
        all[repoID]
    }

    /// The download root for `repoID`, or nil when the repo is unpinned.
    public static func downloadBase(for repoID: String) -> WeightIntegrity.DownloadBase? {
        bases[repoID]
    }
}
