//
//  MLXEmbeddingService.swift
//  M1K3MLX
//
//  On-device embeddings via Apple's MLX framework — Metal GPU, no server. The
//  real semantic embedder that replaces the dependency-free HashingEmbeddingService
//  fallback behind the EmbeddingService seam, so hybrid search becomes genuinely
//  semantic with zero change to KnowledgeStore / RAGResponder.
//
//  Model auto-downloads from HuggingFace on first use and caches in
//  ~/Library/Caches/huggingface/. Subsequent loads are instant.
//
//  Default = Qwen3-Embedding-0.6B (1024-dim, MRL-truncated to 512). A 2026
//  instruction-aware retriever with far wider in/off-domain separation than the
//  old bge_small (384) — bge's ~0.10 noise band is why grounding thresholds sat
//  precariously and confabulation leaked.
//
//  NOT EmbeddingGemma-300m (the first pick): its `EmbeddingGemma.sanitize`
//  mutates a `@ModuleInfo` module property directly after init (Gemma3.swift:477)
//  → `Module.swift:1534: please use Model.update(modules:)` fatal on every load
//  with this mlx-swift-lm pin. Qwen3-Embedding is a BLESSED registry preset
//  (EmbedderRegistry.qwen3_embedding, in `all()`); EmbeddingGemma is only
//  loadable-by-type and carries that latent bug. Revisit gemma once upstream
//  fixes sanitize (or our pin moves past it).
//
//  Signed: Kev + claude-opus-4-8, 2026-06-13, Confidence 0.75,
//  Prior: Kev + claude-opus-4-8, 2026-06-06 (bge_small default)
//  Context: dimension is carried explicitly so callers can size buffers; the
//  768/1024 native width is MRL-truncated + renormalized to `dimension`.
//  Review: Kev + claude-fable-5, 2026-07-09 — `embedQuery` override applies
//  Qwen3-Embedding's asymmetric query instruction via EmbeddingText.forQuery
//  (KEYEVAL-measured; floors re-derived in GroundingGate). Confidence 0.85.
//  Review: Kev + claude-fable-5, 2026-07-16 (concurrency deep pass) — the plain
//  `var modelContainer` cache was an unguarded check-then-act across the ~4s
//  cold load: a launch warm racing a first embed (MCP recall / first chat turn)
//  could load TWO ~600MB containers and race the unsynchronized write. Load is
//  now coalesced through `SingleFlightLoader` — the exact fix MLXBrainProvider
//  adopted for the same bug class on 06-08/09; the embedder was the last
//  straggler. Behaviour otherwise identical (failures clear the slot, so
//  `isAvailable()` retry semantics are preserved).
//  Review: Kev + claude-opus-5-5, 2026-10-07, Confidence 0.85 — kernelTag → mlx-swift-0.32 with the mlx-swift
//  0.31.6 → 0.32.3 / mlx-swift-lm 3.32.3 pair: stores re-index once on next launch, by design (the guard caught it).
//  Review: Kev + claude-fable-5.1, 2026-10-10, Confidence 0.8 — EmbeddingGemma 2 (Stream C slice 2): the
//  `embeddingGemma2` preset loads our own text-core port (EmbeddingGemma2.swift, its own resolve → loadWeights path),
//  and `prompting` picks the card prompts per model — Gemma prefixes BOTH sides, so `embed` composes the
//  document prefix and `embedPrompted` is the raw path the reference stage checks. Qwen stays the default
//  until slice 3's A/B; the 2026-06-13 "NOT EmbeddingGemma" note above is about v1 and the upstream file.
//  Fold (review): `prompting:` is an explicit init parameter (a directory load can't be routed by name), and
//  the Gemma arm's fingerprint carries `gemmaPromptVersion` because its document prefix lives in stored vectors.
//  Review: Kev + claude-fable-5.1, 2026-10-10 (Stream C slice 3) — `preset(named:)` resolves `qwen` / `gemma` /
//  a Hub id for the eval harness. Measured the same day: Gemma separates less than Qwen on every fixture family
//  (docs/evals/2026-10-10-retrieval-evals-*.txt).
//  Review: Kev + claude-fable-5.1, 2026-10-10 (Kev's ruling: ONE embedder) — the default is EmbeddingGemma 2:
//  one checkpoint for text now and the image/audio encoders later, one download, one thing to maintain. Its
//  narrower (but clean) dead zones get their own floors (EmbedderFloors.embeddingGemma2, challenged); the
//  fingerprint change re-indexes every store once on next launch. Qwen stays constructible for the A/B.

import Foundation
import M1K3Inference
import M1K3Knowledge
import MLX
import MLXEmbedders
import MLXLMCommon
import MLXNN

/// Which model-card prompts wrap the text before it is tokenised — and, with
/// it, which loader: MLXEmbedders' factory for Qwen, our port for Gemma.
public enum EmbedderPrompting: Sendable, Equatable {
    /// Qwen3-Embedding: the query carries `EmbeddingText.forQuery`, documents embed bare.
    case qwen3Instruct
    /// EmbeddingGemma 2: `task: search result | query: ` and `title: none | text: `.
    case embeddingGemma2
}

/// `@unchecked Sendable`: model loading is coalesced through a `SingleFlightLoader`
/// actor and the loaded model is itself an isolation actor — MLXEmbedders'
/// `EmbedderModelContainer` (all access inside `perform`) or our
/// `EmbeddingGemma2Embedder`; everything else is immutable.
public final class MLXEmbeddingService: EmbeddingService, @unchecked Sendable {
    /// EmbeddingGemma 2, 8-bit (text fidelity 0.9998 vs Google's fp32 per
    /// mlx-community's validation; 4-bit is 0.981). The checkpoint carries the
    /// vision and audio encoders too; the text core alone is loaded.
    public static let embeddingGemma2 = ModelConfiguration(id: "mlx-community/embeddinggemma-2-8bit")

    /// Gemma's document prefix is baked into every stored vector, so the Gemma
    /// arm carries its own prompt version in the fingerprint: editing
    /// `EmbeddingText.gemmaDocumentPrefix` bumps this and re-indexes. (Qwen's
    /// instruction is query-only and stays unsalted, as before.)
    public static let gemmaPromptVersion = "prompt-v1"

    /// A preset by short name for harnesses (`M1K3_SELFTEST_EMBEDDER`):
    /// `qwen` / `qwen3` → the shipping Qwen3-Embedding, `gemma` / `eg2` →
    /// EmbeddingGemma 2, anything with a slash → that Hub id; nil otherwise.
    /// A Hub id other than the Gemma preset gets Qwen's prompting (the
    /// inferred default) — pass `prompting:` yourself to bench anything else.
    public static func preset(named name: String) -> ModelConfiguration? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        switch trimmed.lowercased() {
        case "", "qwen", "qwen3", "default": return EmbedderRegistry.qwen3_embedding
        case "gemma", "eg2", "embeddinggemma2": return embeddingGemma2
        default: return trimmed.contains("/") ? ModelConfiguration(id: trimmed) : nil
        }
    }

    /// The prompts for `configuration` when none are given: Gemma's for an
    /// EmbeddingGemma 2 id, Qwen's otherwise (bge_small in the A/B harness has
    /// always taken the Qwen instruction, so that is unchanged).
    public static func prompting(for configuration: ModelConfiguration) -> EmbedderPrompting {
        configuration.name.lowercased().contains("embeddinggemma-2") ? .embeddingGemma2 : .qwen3Instruct
    }

    public let prompting: EmbedderPrompting

    /// Single-flights the container load so a launch warm racing a first embed
    /// shares ONE ~600MB load instead of each kicking off their own.
    private let loader: SingleFlightLoader<LoadedEmbedder>
    /// The model this service embeds with (read-only; the loader owns the load).
    public let configuration: ModelConfiguration
    private let onLoadProgress: (@Sendable (Double) -> Void)?

    public let dimension: Int

    /// Hand-bumped whenever the mlx-swift pin changes minor version: the
    /// embedding KERNELS live there, and a kernel change shifts the vector
    /// space even with identical weights. Bumping this fires the store's
    /// auto re-index on next launch (see EmbedderReindexPolicy).
    public static let kernelTag = "mlx-swift-0.32"

    /// Identity of the vector space: model + MRL width + kernel generation.
    /// The `d\(dimension)` segment makes a future MRL truncation change
    /// (e.g. 512→256) a DISTINCT space that re-indexes, even on an unchanged
    /// model id.
    public var fingerprint: String {
        switch prompting {
        case .qwen3Instruct: "mlx/\(configuration.name)/d\(dimension)/\(Self.kernelTag)"
        case .embeddingGemma2: "mlx/\(configuration.name)/d\(dimension)/\(Self.kernelTag)/\(Self.gemmaPromptVersion)"
        }
    }

    /// - Parameters:
    ///   - configuration: MLXEmbedders model. Defaults to Qwen3-Embedding-0.6B
    ///     (the blessed `qwen3_embedding` registry preset) — a 2026 instruction-
    ///     aware retriever with far wider in/off-domain separation than bge-small.
    ///     Pass `EmbedderRegistry.bge_small` (dimension: 384) to stand the legacy
    ///     embedder up beside it (the A/B harness does this).
    ///   - dimension: the TARGET vector width. Qwen3-Embedding emits 1024 and is
    ///     Matryoshka-trained, so `embed` truncates+renormalizes to this width
    ///     (512 = the storage/quality sweet spot). For a non-MRL model pass its
    ///     native width (bge_small = 384) and truncation is a no-op.
    ///   - prompting: the prompts and loader; inferred from the model id when
    ///     nil (a local directory named without "embeddinggemma-2" passes it).
    ///   - onLoadProgress: optional 0...1 callback fired while the model
    ///     downloads on first use, so a re-index can show real download progress
    ///     instead of an indefinite spinner. Nil = silent (the default base
    ///     embedder; only the user-triggered switch wires it up).
    public init(
        configuration: ModelConfiguration = MLXEmbeddingService.embeddingGemma2,
        dimension: Int = 512,
        prompting: EmbedderPrompting? = nil,
        onLoadProgress: (@Sendable (Double) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.dimension = dimension
        self.onLoadProgress = onLoadProgress
        self.prompting = prompting ?? Self.prompting(for: configuration)
        let prompting = self.prompting
        loader = SingleFlightLoader { progress in
            switch prompting {
            case .embeddingGemma2:
                // Our own port: MLXEmbedders at this pin has no Gemma-4 embedder.
                let embedder = try await EmbeddingGemma2Embedder.load(
                    configuration: configuration,
                    from: HubApiDownloader.embedderDefault,
                    tokenizerLoader: TransformersTokenizerLoader(),
                    progressHandler: { prog in progress(prog.fractionCompleted) }
                )
                return .gemma(embedder)
            case .qwen3Instruct:
                let container = try await EmbedderModelFactory.shared.loadContainer(
                    from: HubApiDownloader.embedderDefault,
                    using: TransformersTokenizerLoader(),
                    configuration: configuration,
                    progressHandler: { prog in progress(prog.fractionCompleted) }
                )
                return .upstream(container)
            }
        }
    }

    /// The two load paths behind one seam: MLXEmbedders' container for its own
    /// models, our EmbeddingGemma 2 actor for the port.
    enum LoadedEmbedder {
        case upstream(EmbedderModelContainer)
        case gemma(EmbeddingGemma2Embedder)
    }

    /// Query side, per `prompting`. Qwen3-Embedding's official asymmetric
    /// convention: queries carry the retrieval instruction, documents embed
    /// bare. Routes through EmbeddingText.forQuery — the SAME composer the
    /// KEYEVAL harness measures, so the instrument and production can never
    /// drift apart. Measured 2026-07-09 (KEYEVAL, on-device): the instruction
    /// crushes the noise ceiling (mixed 0.432→0.203, memory negatives
    /// 0.422→0.260, chunk off-domain 0.315→0.234) — which is what let the
    /// GroundingGate floors move down to admit the keyword register. Query
    /// composition never touches stored vectors, so it is not in `fingerprint`.
    /// Gemma prefixes both sides (`composeDocument`), hence its prompt salt.
    public func embedQuery(_ text: String) async throws -> [Float] {
        try await embedPrompted(composeQuery(text))
    }

    /// Document side: bare for Qwen, `title: none | text: ` for Gemma.
    public func embed(_ text: String) async throws -> [Float] {
        try await embedPrompted(composeDocument(text))
    }

    func composeQuery(_ text: String) -> String {
        switch prompting {
        case .qwen3Instruct: EmbeddingText.forQuery(text)
        case .embeddingGemma2: EmbeddingText.forGemmaQuery(text)
        }
    }

    func composeDocument(_ text: String) -> String {
        switch prompting {
        case .qwen3Instruct: text
        case .embeddingGemma2: EmbeddingText.forGemmaDocument(text)
        }
    }

    /// The token ids `text` (taken as given) embeds as — the reference stage
    /// compares them with the Python tokenizer's before trusting a vector.
    public func tokenize(_ text: String) async throws -> [Int] {
        switch try await ensureLoaded() {
        case let .gemma(embedder): await embedder.tokenize(text)
        case let .upstream(container): await container.perform { $0.tokenizer.encode(text: text) }
        }
    }

    /// Embeds `text` exactly as given — no prompt composition. The reference
    /// stage uses it to feed the fixture's already-prompted strings; production
    /// goes through `embed` / `embedQuery`.
    public func embedPrompted(_ text: String) async throws -> [Float] {
        let loaded = try await ensureLoaded()
        // Per-embed reclaim is intentional: prefer OS round-trips over peak
        // accumulation during a bulk re-index (hundreds of chunks).
        defer { MLXMemoryBudget.reclaim(label: "embed") }

        let raw: [Float]
        switch loaded {
        case let .gemma(embedder):
            raw = await embedder.embed(text)
        case let .upstream(container):
            raw = await Self.embedUpstream(text, in: container)
        }

        // MRL: take the leading `dimension` dims and re-normalize. `truncate-
        // Validated` throws loudly if the model emitted FEWER dims than we
        // target (a mis-converted checkpoint), rather than silently degrading
        // the whole vector space. For a native-width model (bge_small=384,
        // dimension=384) this is a no-op pass-through.
        return try MatryoshkaTruncation.truncateValidated(raw, to: dimension)
    }

    private static func embedUpstream(_ text: String, in container: EmbedderModelContainer) async -> [Float] {
        await container.perform { context in
            let tokenIds = context.tokenizer.encode(text: text)
            let inputIds = MLXArray(tokenIds.map { Int32($0) }).expandedDimensions(axis: 0)
            let mask = MLXArray([Int32](repeating: 1, count: tokenIds.count)).expandedDimensions(axis: 0)

            let output = context.model(inputIds, positionIds: nil, tokenTypeIds: nil, attentionMask: mask)
            // `normalize: true` is load-bearing, and backend-dependent:
            //   • Qwen3-Embedding returns raw hidden states (pooledOutput == nil,
            //     poolingStrategy == .last) → this call does BOTH the last-token
            //     pooling AND the only L2-norm. Drop it and cosines break.
            //   • bge_small mean-pools here and relies on this norm entirely.
            //   • A self-normalizing backend would make it idempotent — harmless.
            // So: always normalize → every backend yields a unit vector by
            // construction. (The MRL renorm below re-normalizes the TRUNCATED
            // prefix; that one is separately load-bearing.)
            let pooled = context.pooling(output, mask: mask, normalize: true)

            // Must eval before leaving perform — MLXArray is not Sendable.
            let result = pooled.squeezed()
            eval(result)
            return result.asArray(Float.self)
        }
    }

    public func isAvailable() async -> Bool {
        do {
            _ = try await ensureLoaded()
            return true
        } catch {
            return false
        }
    }

    private func ensureLoaded() async throws -> LoadedEmbedder {
        // The embedder shares the process-global MLX memory state with the LLM
        // and can be the first MLX code to run (ingest before any chat turn).
        MLXMemoryBudget.applyOnce()
        let report = onLoadProgress
        return try await loader.value { report?($0) }
    }
}
