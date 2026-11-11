# Vendored: Blaizzy/mlx-audio-swift (StyleTTS2 / Kokoro)

Source: https://github.com/Blaizzy/mlx-audio-swift
Commit: `542fffacb3be8de47024b3b54888f71d72d46d30` (2026-07-17 13:16:34 -0700)
Vendored: 2026-07-18
License: MIT (see `LICENSE` in this directory — the license from the upstream
repository, copyright Prince Canuma / mlx-audio-swift contributors).

## Why vendored, not a package dependency

`mlx-audio-swift` ships as a single `MLXAudioTTS` product bundling every
supported TTS architecture (StyleTTS2/Kokoro, KittenTTS, Qwen3TTS, Chatterbox,
FishSpeech, Marvis, …) plus its own G2P/tokenizer stack and a `HuggingFace`
download client. Pulling in the whole package would drag a second HF client
(alongside M1K3's existing `swift-transformers`-based one — the same clash
class documented in `../../../macos/CLAUDE.md`'s Tokenizers landmine) and a
second phonemizer M1K3 does not use (`KokoroG2P.swift`, one directory up, is
M1K3's own tested IP — the dictionary is swappable, the assembly logic is
not). So only the **StyleTTS2/Kokoro model definition** is vendored: the pure
MLX/MLXNN neural-net modules (attention, LSTM, convolutions, the ISTFT
generator) and the config decoders. Everything HF-client/tokenizer-shaped from
the original `KokoroModel.swift` was cut — see below.

Note: this repo's SwiftFormat pre-commit hook mechanically reformats every
staged file (import ordering, `0..<x` → `0 ..< x` spacing, etc.) — the
vendored files below carry that house-style pass on top of the upstream
source. It is whitespace/ordering only; no vendored logic was hand-edited
beyond what's called out under "Local modifications" below.

## What's here

| File | Role |
|---|---|
| `Albert.swift` | The PL-BERT text encoder (ALBERT architecture) that produces the BERT hidden states the prosody predictor conditions on. |
| `SharedConfigs.swift` | `ISTFTNetConfig` + `PLBertConfig` — the two nested config structs `KokoroConfig` decodes. |
| `Blocks/*.swift` | Reusable StyleTTS2 building blocks: `BiLSTM` (hand-rolled bidirectional LSTM cell, MLX has no built-in), `LinearNorm`, `AdaIN1d`/`AdaLayerNorm` (style-conditioned normalization), `AdainResBlock1d`/`AdaINResBlock1` (residual blocks, snake activation for the generator), `SineGenerator`/`SourceModule` (the harmonic F0 source for the vocoder), `UpSample1d`, `WeightNormedConv` (weight-normalized conv1d/conv-transpose1d, the `weight_g`/`weight_v` decomposition PyTorch checkpoints use), `Utilities.swift` (`interpolate1d`, used by `SineGenerator`'s up/downsampling). |
| `Kokoro/KokoroConfig.swift` | The `Decodable` config matching Kokoro's `config.json` (vocab map, model dims, ISTFT/PLBert sub-configs, optional quantization). |
| `Kokoro/KokoroModules.swift` | `KokoroTextEncoder` (CNN+BiLSTM over token embeddings), `KokoroDurationEncoder`, `KokoroProsodyPredictor` (duration + F0/N prediction). |
| `Kokoro/KokoroDecoder.swift` | The ISTFTNet vocoder: `KokoroSTFT` (hand-rolled STFT/iSTFT — MLXFFT has no windowed-frame helper), `KokoroGenerator`, `KokoroDecoder`. |
| `Kokoro/KokoroModel.swift` | **Locally modified — see below.** The top-level module tree (`bert`/`bertEncoder`/`predictor`/`textEncoder`/`decoder`) + `callAsFunction` forward pass + weight `sanitize`/`quantizeTree`. |

## Deliberately NOT vendored (per the integration brief)

- `Kokoro/KokoroMultilingualProcessor.swift` — non-English language routing;
  M1K3 speaks English only (`KokoroG2P` is en-GB).
- `G2P/*` (the whole directory: `EnglishG2P`, the BART fallback network,
  `Lexicon`, `MisakiTextProcessor`, …) — M1K3 has its own tested phonemizer
  (`../../KokoroG2P.swift`) targeting the SAME canonical Kokoro v1.0 vocab
  (verified byte-for-byte against `mlx-community/Kokoro-82M-bf16`'s
  `config.json` vocab map before this port began — punctuation ids 1–15,
  space=16, and the inflection-suffix phoneme ids 46/58/61/62/68/82/102/
  119/131/133/147 all match the upstream vocab's id→IPA-character table).
- `KittenTTS/*` — a different (non-Kokoro) TTS architecture bundled in the
  same upstream directory.

## Local modification, 2026-11-11: guarded reads

`KokoroModel.callAsFunction` now `throws`, and its one mid-pass read
(`predDur.asArray`) goes through `KokoroGuardedRead.values` (a sibling,
non-vendored file). An MLX failure there used to be a `fatalError`; a tester's
1.3.0 crash showed it happening with the app in the background. No maths changed.

## Local modifications to `KokoroModel.swift`

The upstream file is a `SpeechGenerationModel` conforming to mlx-audio-swift's
own generation protocol, with `fromPretrained`/`ModelUtils.resolveOrDownload
Model` (HuggingFace Hub client), `tokenize(_:)` (a `config.vocab[String
(unicodeScalar)]` IPA-character tokenizer fed by mlx-audio-swift's own G2P),
`loadVoice`/`availableVoices` (per-voice `.safetensors` files in a `voices/`
subdirectory), and `generate`/`generateStream` (text-in, audio-out, calling
its own tokenizer + voice loader).

M1K3 already owns its own token pipeline end to end
(`KokoroG2P.annotatedTokens` → the SAME canonical vocab ids) and its own style
vectors (`KokoroVoices.style(voice:tokenCount:)`, read from the historical
`voices-v1.0.bin` npz — kept as-is, not the new repo's per-voice
`.safetensors` files). So the vendored `KokoroModel.swift` keeps only:

- the module tree + `init` (unchanged),
- `callAsFunction(inputIds:refS:speed:)` — the forward pass (unchanged),
- `sanitize(weights:)` — the PyTorch→MLX key remap + conv-transpose fixups
  (unchanged),
- `fromModelDirectory` — decode `config.json`, load `model.safetensors`,
  sanitize, optionally quantize, `update(parameters:)` (unchanged apart from
  dropping the `textProcessor?.prepare()` call, since there is no
  `textProcessor` here),
- `quantizeTree`/`loadWeights` (unchanged).

Removed: the `SpeechGenerationModel` conformance, `@unchecked Sendable`
(M1K3's own `Loaded` box in `KokoroSynthesizer.swift` owns the Sendable
story), `textProcessor`, `tokenize`, `generate`, `generateStream`,
`loadVoice`, `availableVoices`, `setTextProcessor`, `fromPretrained`
(HuggingFace-Hub-backed), and the `import HuggingFace` / `import
MLXAudioCore` / `@preconcurrency import MLXLMCommon` lines that only those
removed methods needed (`MLXLMCommon` is still imported — `KokoroConfig`'s
`quantization: BaseConfiguration.Quantization?` field needs the type).

Also locally modified (behavior-preserving refactor): `sanitize(weights:)`'s
per-key string remap (the `.weight_ih_l0_reverse` → `.Wx_backward` table and
friends) was extracted into `KokoroMLXWeightKeyMap.remap(_:)` — a sibling,
NOT-vendored, pure `String → String?` function one directory up — so that
remap can be red-first unit-tested without ever touching `MLXArray` (which
needs Metal at eval time; see the metallib wall in `../../CLAUDE.md`). Same
rules, same order (reverse-before-forward, so a reverse key never partial-
matches the forward pattern), byte-identical output to upstream.

M1K3's own adapter code that replaces the removed surface —
loading from the app's staged model directory, running inference on the
pipeline's assembled tokens/style — lives one directory up in
`KokoroSynthesizer.swift` (not vendored; that file carries its own
MurphySig), alongside `KokoroMLXInput.swift` (the pad-wrap token assembly)
and `KokoroMLXWeightKeyMap.swift` (the extracted sanitize key-remap, above).
