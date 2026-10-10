//
//  EmbedderFloorsTests.swift
//  M1K3KnowledgeTests
//
//  Per-embedder relevance floors: GroundingGate's thresholds were measured on
//  instructed qwen3-embed-512; HashingEmbeddingService (the Mac offline
//  fallback and the ONLY iOS/visionOS embedder) lives in a completely
//  different cosine cone (bag-of-words token overlap), measured 2026-07-31 in
//  HashingFloorTests. These tests pin the selection seam: fingerprint →
//  floors, and the gate honouring the floors it is handed.
//
//  Signed: Kev + claude-fable-5, 2026-07-31, Confidence 0.85 (selection +
//  gate plumbing pinned here; the hashing numbers themselves are pinned
//  against the measured distributions in HashingFloorTests). Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-10-10 (one embedder: EmbeddingGemma 2) — Gemma identity /
//  variant-fails-closed / carried-bars tests.
//

import Foundation
@testable import M1K3Knowledge
import Testing

struct EmbedderFloorsTests {
    private func hit(kind: KnowledgeKind, similarity: Float?) -> ChunkHit {
        ChunkHit(
            chunkID: UUID(),
            itemID: UUID(),
            itemTitle: "Doc",
            kind: kind,
            heading: nil,
            content: "content",
            similarity: similarity,
            rrfScore: 0.016
        )
    }

    // MARK: - Fingerprint selection

    @Test("hashing fingerprints select the hashing floors, bare and store-composed")
    func hashingSelection() {
        #expect(EmbedderFloors.forFingerprint("hashing/v1") == .hashing)
        // Store fingerprints carry the composition suffix (EmbeddingText.storeFingerprint).
        #expect(EmbedderFloors.forFingerprint("hashing/v1+title-v1") == .hashing)
    }

    @Test("EmbeddingGemma 2's measured identity selects its own floors, bare, store-composed, any kernel tag")
    func gemmaFingerprintsSelectGemma() {
        let bare = "mlx/mlx-community/embeddinggemma-2-8bit/d512/mlx-swift-0.32/prompt-v1"
        #expect(EmbedderFloors.forFingerprint(bare) == .embeddingGemma2)
        #expect(EmbedderFloors.forFingerprint(bare + "+title-v1") == .embeddingGemma2)
        #expect(EmbedderFloors.forFingerprint(
            "mlx/mlx-community/embeddinggemma-2-8bit/d512/mlx-swift-0.33/prompt-v1"
        ) == .embeddingGemma2, "a kernel bump re-indexes; the cone is the same model")
        // Measured 2026-10-10 (docs/evals/2026-10-10-retrieval-evals-gemma.txt): the
        // bars sit between the worst negative and the weakest positive of each family.
        let gemma = EmbedderFloors.embeddingGemma2
        #expect(gemma.memory > 0.643 && gemma.memory < 0.700, "keyword probes bind the memory bar")
        #expect(gemma.chunk > 0.548 && gemma.chunk < 0.779)
        #expect(gemma.edge >= gemma.chunk)
        #expect(gemma.dedupe > 0.886, "a reworded question scores 0.886 against its fact — not a twin")
        #expect(gemma.forgetSuggestion == gemma.memory)
    }

    @Test("an unmeasured EmbeddingGemma 2 variant fails closed: the strictest known bar per lane")
    func gemmaVariantsFailClosed() {
        let fourBit = "mlx/mlx-community/embeddinggemma-2-4bit/d512/mlx-swift-0.32/prompt-v1"
        let narrower = "mlx/mlx-community/embeddinggemma-2-8bit/d256/mlx-swift-0.32/prompt-v1"
        let promptV2 = "mlx/mlx-community/embeddinggemma-2-8bit/d512/mlx-swift-0.32/prompt-v2"
        let promptV10 = "mlx/mlx-community/embeddinggemma-2-8bit/d512/mlx-swift-0.32/prompt-v10"
        let malformed = "mlx/mlx-community/embeddinggemma-2-8bit/d512/mlx-swift-0.32/prompt-v1x+title-v1"
        let strict = EmbedderFloors.strictest(of: [.qwen3Instructed, .embeddingGemma2])
        for fingerprint in [fourBit, narrower, promptV2, promptV10, malformed] {
            #expect(EmbedderFloors.forFingerprint(fingerprint) == strict, Comment(rawValue: fingerprint))
        }
        #expect(strict.chunk == max(EmbedderFloors.qwen3Instructed.chunk, EmbedderFloors.embeddingGemma2.chunk))
        #expect(strict.dedupe == max(EmbedderFloors.qwen3Instructed.dedupe, EmbedderFloors.embeddingGemma2.dedupe))
    }

    @Test("the bars that lived as constants are carried by every set, unchanged for Qwen and hashing")
    func carriedBars() {
        #expect(EmbedderFloors.qwen3Instructed.dedupe == 0.90)
        #expect(EmbedderFloors.qwen3Instructed.forgetSuggestion == 0.35)
        #expect(EmbedderFloors.hashing.dedupe == 0.90)
        #expect(EmbedderFloors.hashing.forgetSuggestion == 0.35)
    }

    @Test("an unknown mlx embedder is DELIBERATELY the legacy qwen3 set — a third embedder adds its own branch")
    func unknownEmbedderIsTheLegacyDefault() {
        // Pinned on purpose: test doubles and pre-2026-10 Qwen kernels live here. The
        // fail-closed rule applies only inside the EmbeddingGemma 2 family; a NEW family
        // must measure its cone and add a branch, not inherit this one silently.
        #expect(EmbedderFloors.forFingerprint("mlx/some-org/new-embedder/d512/mlx-swift-0.32") == .qwen3Instructed)
    }

    @Test("non-hashing, non-Gemma fingerprints select the instructed qwen3 defaults")
    func qwenSelection() {
        #expect(EmbedderFloors.forFingerprint("mlx/qwen3-embed-512/mlx-swift-0.30") == .qwen3Instructed)
        #expect(EmbedderFloors.forFingerprint("") == .qwen3Instructed)
    }

    @Test("the gate's legacy constants ARE the qwen3 floors — one source of truth")
    func constantsMirrorQwenFloors() {
        #expect(GroundingGate.chunkThreshold == EmbedderFloors.qwen3Instructed.chunk)
        #expect(GroundingGate.memoryThreshold == EmbedderFloors.qwen3Instructed.memory)
        #expect(GroundingGate.edgeThreshold == EmbedderFloors.qwen3Instructed.edge)
    }

    @Test("the edge bar is shared: hashing keeps the conservative 0.51")
    func edgeBarShared() {
        #expect(EmbedderFloors.hashing.edge == EmbedderFloors.qwen3Instructed.edge)
    }

    // MARK: - Gate honours the floors it is handed

    @Test("a hashing-cone memory hit recalls under hashing floors, drops under qwen floors")
    func memoryFloorDivergence() {
        // 0.2 is a healthy hashing memory cosine (shared content token) but
        // sub-floor noise in the qwen cone.
        let memory = hit(kind: .memory, similarity: 0.2)
        #expect(GroundingGate.partition([memory]).memories.isEmpty)
        #expect(GroundingGate.partition([memory], floors: .hashing).memories.count == 1)
    }

    @Test("a hashing-cone chunk hit clears hashing floors, not qwen floors")
    func chunkFloorDivergence() {
        // 0.36: above hashing's measured dead-band centre (0.35), below qwen's 0.37.
        let chunk = hit(kind: .document, similarity: 0.36)
        #expect(GroundingGate.partition([chunk]).knowledge.isEmpty)
        #expect(GroundingGate.partition([chunk], floors: .hashing).knowledge.count == 1)
        #expect(GroundingGate.relevant([chunk]).isEmpty)
        #expect(GroundingGate.relevant([chunk], floors: .hashing).count == 1)
    }

    @Test("sub-floor noise still drops under hashing floors")
    func hashingFloorsStillGate() {
        let noise = [
            hit(kind: .memory, similarity: 0.05), // below hashing memory 0.10
            hit(kind: .document, similarity: 0.30), // measured off-domain ceiling territory
        ]
        let (knowledge, memories) = GroundingGate.partition(noise, floors: .hashing)
        #expect(knowledge.isEmpty)
        #expect(memories.isEmpty)
    }

    @Test("FTS-only hits never clear, whatever the floors")
    func ftsOnlyNeverClears() {
        let ftsOnly = hit(kind: .document, similarity: nil)
        #expect(GroundingGate.relevant([ftsOnly], floors: .hashing).isEmpty)
        #expect(GroundingGate.partition([ftsOnly], floors: .hashing).knowledge.isEmpty)
    }
}
