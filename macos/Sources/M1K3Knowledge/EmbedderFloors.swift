//
//  EmbedderFloors.swift
//  M1K3Knowledge
//
//  Per-embedder relevance floors. GroundingGate's bars are measured
//  distributions, not universal truths: the instructed qwen3-embed-512 cone
//  (dead zones derived on-device via ABSEP/MEMEVAL/KEYEVAL, 2026-06-14 →
//  07-09) and HashingEmbeddingService's bag-of-words cone are different
//  shapes entirely. Sharing one set of numbers silently broke iOS — hashing
//  is the ONLY mobile embedder, and under the qwen floors the measured
//  hashing arm keeps just 6 of 22 true memory recalls (HashingFloorTests).
//
//  Selection is by embedder fingerprint — the same identity the store
//  records with its vectors — so the floors follow the vectors, including
//  runtime swaps through SwappableEmbeddingService (MLX warm ⇄ hashing
//  fallback) and store fingerprints carrying the "+title-v1" composition
//  suffix.
//
//  Signed: Kev + claude-fable-5, 2026-07-31, Confidence 0.85 (hashing floors
//  derived from the deterministic hashing arm over the SAME fixture sets
//  that set the qwen floors, pinned in HashingFloorTests; the edge bar is
//  deliberately unmeasured-conservative — see its comment). Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-10-10 (Stream C, Kev's one-embedder ruling) — `embeddingGemma2`
//  floors from the same fixture sets. Confidence 0.75: clean on every family but thin (0.03) margins on
//  the memory register; edge and dedupe are unmeasured/provisional. The challenger closed the seam: the
//  struct now carries EVERY embedder-dependent bar (`dedupe`, `forgetSuggestion`), the Gemma identity is
//  matched exactly with other family members failing closed (`strictest`), and MemoryStore / the
//  distiller / ForgetResolver read these instead of Qwen constants.
//

import Foundation

/// The three relevance bars a gate needs, as one selectable value.
public struct EmbedderFloors: Sendable, Equatable {
    /// Minimum cosine for a chunk to be injected as grounding.
    public let chunk: Float
    /// Minimum cosine for a memory hit to feed the memory block.
    public let memory: Float
    /// Minimum content↔content cosine for a memory-graph edge.
    public let edge: Float
    /// Cosine at/above which a distilled fact counts as "already known"
    /// (superseded on write — the dream-cycle Tier-2 dedupe bar).
    public let dedupe: Float
    /// The bar for OFFERING a near-miss on a forget request ("Closest: …
    /// repeat it back"). Below it the top hit is a random fact, and inviting
    /// a word-for-word repeat of a random fact is a consent hazard.
    public let forgetSuggestion: Float

    public init(chunk: Float, memory: Float, edge: Float, dedupe: Float, forgetSuggestion: Float) {
        self.chunk = chunk
        self.memory = memory
        self.edge = edge
        self.dedupe = dedupe
        self.forgetSuggestion = forgetSuggestion
    }

    /// The highest bar of every known set, per lane — what an unmeasured
    /// embedder gets, so an unknown cone loses recall rather than leaks.
    public static func strictest(of sets: [EmbedderFloors]) -> EmbedderFloors {
        EmbedderFloors(
            chunk: sets.map(\.chunk).max() ?? 1,
            memory: sets.map(\.memory).max() ?? 1,
            edge: sets.map(\.edge).max() ?? 1,
            dedupe: sets.map(\.dedupe).max() ?? 1,
            forgetSuggestion: sets.map(\.forgetSuggestion).max() ?? 1
        )
    }

    /// Instructed qwen3-embed-512 — the on-device-measured defaults
    /// (rationale and full distributions: GroundingGate's per-constant
    /// comments, which these values ARE — the gate's legacy constants
    /// delegate here).
    /// dedupe 0.90 and forgetSuggestion 0.35 are the bars that lived as
    /// constants in MemoryDistillationCoordinator and ForgetResolver until
    /// 2026-10-10 (measured on this embedder: compatibles max 0.768).
    public static let qwen3Instructed = EmbedderFloors(
        chunk: 0.37, memory: 0.35, edge: 0.51, dedupe: 0.90, forgetSuggestion: 0.35
    )

    /// hashing/v1 — measured 2026-07-31 over the same MEMEVAL/ABSEP fixture
    /// sets, deterministic so the measurement runs in CI (HashingFloorTests
    /// re-derives and pins these):
    /// - memory 0.10, recall-first (the same asymmetry that set qwen's bar):
    ///   positives span 0.0–0.589 with four at literally 0.0 — synonym pairs
    ///   bag-of-words cannot see, unsavable by any floor. 0.10 keeps 18/22
    ///   true recalls (vs 6/22 under the shared 0.35) at the cost of stray
    ///   uncited one-liners (neg ceiling 0.408 — there is NO clean cut).
    /// - chunk 0.35, precision-first (chunk injection derails small models):
    ///   the dead-band centre between the measured off-domain noise ceiling
    ///   (0.304, mostly stop-word overlap) and the surviving in-domain floor
    ///   (0.402). In-domain hits below the noise ceiling (0.045–0.270) are
    ///   unreachable: any floor admitting them admits the noise too.
    /// - edge 0.51, UNMEASURED, deliberately shared with qwen: a permanent
    ///   graph edge should mean substantial overlap, and 0.51 bag-of-words
    ///   cosine IS heavy token overlap — conservative in the right
    ///   direction. Measure before lowering (no fact↔fact fixture set yet).
    /// dedupe 0.90 / forgetSuggestion 0.35: the shared constants the hashing
    /// arm ran under before the seam carried them — unchanged, unmeasured.
    public static let hashing = EmbedderFloors(
        chunk: 0.35, memory: 0.10, edge: 0.51, dedupe: 0.90, forgetSuggestion: 0.35
    )

    /// EmbeddingGemma 2 (8-bit, MRL 512, card prompts both sides) — measured
    /// 2026-10-10 over the same MEMEVAL / ABSEP / KEYEVAL fixture sets
    /// (docs/evals/2026-10-10-retrieval-evals-gemma.txt), production arms.
    /// Its cone is compressed and sits ~0.3 above Qwen's: clean separation on
    /// every family, narrower dead zones.
    /// Challenged 2026-10-10 (the keyword probes bind the MEMORY bar, not the
    /// chunk bar: 7 of 10 probes target memory facts):
    /// - memory 0.67: positives 0.707–0.875, negatives 0.535–0.628; the
    ///   keyword probes' noise ceiling is 0.643 against a positive floor of
    ///   0.700, so 0.67 is the only bar the data allows (22/22, 10/10, 0 leaks;
    ///   margin 0.027 / 0.030 — thin; per-query normalisation is the lever).
    /// - chunk 0.70: in-domain 0.779–0.878 vs off-domain ≤ 0.548 — 0.079
    ///   below the weakest chunk, 0.15 above the noise, precision-first (the
    ///   chunk lane's doctrine: injected chunks derail small models).
    /// - edge 0.75: UNMEASURED (no fact↔fact fixture set); the bare arm's
    ///   noise ceiling 0.694 is the best stand-in for unrelated fact↔fact
    ///   pairs. Measure (MEMSTAT with this embedder) before lowering.
    /// - dedupe 0.95: MEMSTAT's probe classes with this embedder
    ///   (docs/evals/2026-10-10-memstat-gemma.txt): restatements 0.955–0.975,
    ///   contradictions 0.890–0.944, compatibles 0.803–0.896 — 0.95 eats 5/5
    ///   restatements and 0/10 contradictions. (Qwen at its 0.90 eats 3/10
    ///   contradictions — lost corrections — and 4/5 restatements.) The
    ///   0.944 / 0.955 gap is thin; a missed dedupe is a duplicate, an eaten
    ///   contradiction a lost correction, so lean high, never lower.
    /// - forgetSuggestion 0.67: the memory bar's register, as for Qwen.
    public static let embeddingGemma2 = EmbedderFloors(
        chunk: 0.70, memory: 0.67, edge: 0.75, dedupe: 0.95, forgetSuggestion: 0.67
    )

    /// The exact measured identity: repo, MRL width and prompt version. The
    /// kernel tag between them may move (a kernel bump re-indexes anyway).
    public static let embeddingGemma2IdentityPrefix = "mlx/mlx-community/embeddinggemma-2-8bit/d512/"
    public static let embeddingGemma2IdentitySuffix = "/prompt-v1"
    /// Any EmbeddingGemma 2 fingerprint that is NOT the measured identity
    /// (a 4-bit checkpoint, another width, a prompt-v2): unmeasured.
    public static let embeddingGemma2FamilyPrefix = "mlx/mlx-community/embeddinggemma-2"
    /// The exact identity `MLXEmbeddingService` gives Qwen3-Embedding 0.6B at 512.
    public static let qwen3IdentityPrefix = "mlx/mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ/d512/"

    /// Floors for an embedder (or store) fingerprint. Matches the hashing
    /// family by prefix so "hashing/v1" and the store-composed
    /// "hashing/v1+title-v1" both select the hashing floors; EmbeddingGemma 2
    /// only at its measured identity (repo + width + prompt version — the
    /// store suffix "+title-v1" may follow), with any OTHER member of that
    /// family getting the strictest known bars (fail closed: an unmeasured
    /// cone loses recall, never leaks); every other fingerprint gets the
    /// instructed qwen3 set, the legacy default (test doubles, earlier Qwen
    /// kernels — the cone every pre-2026-10 store was measured in).
    public static func forFingerprint(_ fingerprint: String) -> EmbedderFloors {
        if fingerprint.hasPrefix("hashing/") { return .hashing }
        if fingerprint.hasPrefix(embeddingGemma2FamilyPrefix) {
            let identity = fingerprint.hasPrefix(embeddingGemma2IdentityPrefix)
                && (fingerprint.hasSuffix(embeddingGemma2IdentitySuffix)
                    || fingerprint.contains(embeddingGemma2IdentitySuffix + "+"))
            return identity ? .embeddingGemma2 : .strictest(of: [.qwen3Instructed, .embeddingGemma2])
        }
        return .qwen3Instructed
    }
}
