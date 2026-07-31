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

    public init(chunk: Float, memory: Float, edge: Float) {
        self.chunk = chunk
        self.memory = memory
        self.edge = edge
    }

    /// Instructed qwen3-embed-512 — the on-device-measured defaults
    /// (rationale and full distributions: GroundingGate's per-constant
    /// comments, which these values ARE — the gate's legacy constants
    /// delegate here).
    public static let qwen3Instructed = EmbedderFloors(chunk: 0.37, memory: 0.35, edge: 0.51)

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
    public static let hashing = EmbedderFloors(chunk: 0.35, memory: 0.10, edge: 0.51)

    /// Floors for an embedder (or store) fingerprint. Matches the hashing
    /// family by prefix so "hashing/v1" and the store-composed
    /// "hashing/v1+title-v1" both select the hashing floors; every other
    /// fingerprint gets the instructed qwen3 defaults (they were the only
    /// measured numbers before this seam existed — unknown embedders
    /// inherit the strict cone, not the lax one).
    public static func forFingerprint(_ fingerprint: String) -> EmbedderFloors {
        fingerprint.hasPrefix("hashing/") ? .hashing : .qwen3Instructed
    }
}
