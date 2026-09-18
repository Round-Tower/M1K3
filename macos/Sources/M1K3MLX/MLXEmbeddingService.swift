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

import Foundation
import M1K3Inference
import M1K3Knowledge
import MLX
import MLXEmbedders
import MLXLMCommon
import MLXNN

/// `@unchecked Sendable`: model loading is coalesced through a `SingleFlightLoader`
/// actor and the loaded `EmbedderModelContainer` is itself an isolation actor (all
/// model access is actor-isolated inside `perform`); everything else is immutable.
public final class MLXEmbeddingService: EmbeddingService, @unchecked Sendable {
    /// Single-flights the container load so a launch warm racing a first embed
    /// shares ONE ~600MB load instead of each kicking off their own.
    private let loader: SingleFlightLoader<EmbedderModelContainer>
    private let configuration: ModelConfiguration
    private let onLoadProgress: (@Sendable (Double) -> Void)?

    public let dimension: Int

    /// Hand-bumped whenever the mlx-swift pin changes minor version: the
    /// embedding KERNELS live there, and a kernel change shifts the vector
    /// space even with identical weights. Bumping this fires the store's
    /// auto re-index on next launch (see EmbedderReindexPolicy).
    public static let kernelTag = "mlx-swift-0.31"

    /// Identity of the vector space: model + MRL width + kernel generation.
    /// The `d\(dimension)` segment makes a future MRL truncation change
    /// (e.g. 512→256) a DISTINCT space that re-indexes, even on an unchanged
    /// model id.
    public var fingerprint: String {
        "mlx/\(configuration.name)/d\(dimension)/\(Self.kernelTag)"
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
    ///   - onLoadProgress: optional 0...1 callback fired while the model
    ///     downloads on first use, so a re-index can show real download progress
    ///     instead of an indefinite spinner. Nil = silent (the default base
    ///     embedder; only the user-triggered switch wires it up).
    public init(
        configuration: ModelConfiguration = EmbedderRegistry.qwen3_embedding,
        dimension: Int = 512,
        onLoadProgress: (@Sendable (Double) -> Void)? = nil
    ) {
        self.configuration = configuration
        self.dimension = dimension
        self.onLoadProgress = onLoadProgress
        loader = SingleFlightLoader { progress in
            try await EmbedderModelFactory.shared.loadContainer(
                from: HubApiDownloader.embedderDefault,
                using: TransformersTokenizerLoader(),
                configuration: configuration,
                progressHandler: { prog in progress(prog.fractionCompleted) }
            )
        }
    }

    /// Query-side asymmetry (Qwen3-Embedding's official convention): user
    /// queries carry the retrieval instruction; documents embed bare via
    /// `embed`. Routes through EmbeddingText.forQuery — the SAME composer the
    /// KEYEVAL harness measures, so the instrument and production can never
    /// drift apart. Measured 2026-07-09 (KEYEVAL, on-device): the instruction
    /// crushes the noise ceiling (mixed 0.432→0.203, memory negatives
    /// 0.422→0.260, chunk off-domain 0.315→0.234) — which is what let the
    /// GroundingGate floors move down to admit the keyword register.
    /// NOT part of `fingerprint`: query composition never touches stored
    /// vectors, so it must not trigger a corpus re-embed.
    public func embedQuery(_ text: String) async throws -> [Float] {
        try await embed(EmbeddingText.forQuery(text))
    }

    public func embed(_ text: String) async throws -> [Float] {
        let container = try await ensureLoaded()
        // Per-embed reclaim is intentional: prefer OS round-trips over peak
        // accumulation during a bulk re-index (hundreds of chunks).
        defer { MLXMemoryBudget.reclaim(label: "embed") }

        let raw: [Float] = await container.perform { context in
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

        // MRL: take the leading `dimension` dims and re-normalize. `truncate-
        // Validated` throws loudly if the model emitted FEWER dims than we
        // target (a mis-converted checkpoint), rather than silently degrading
        // the whole vector space. For a native-width model (bge_small=384,
        // dimension=384) this is a no-op pass-through.
        return try MatryoshkaTruncation.truncateValidated(raw, to: dimension)
    }

    public func isAvailable() async -> Bool {
        do {
            _ = try await ensureLoaded()
            return true
        } catch {
            return false
        }
    }

    private func ensureLoaded() async throws -> EmbedderModelContainer {
        // The embedder shares the process-global MLX memory state with the LLM
        // and can be the first MLX code to run (ingest before any chat turn).
        MLXMemoryBudget.applyOnce()
        let report = onLoadProgress
        return try await loader.value { report?($0) }
    }
}
