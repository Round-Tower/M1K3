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

    @Test("non-hashing fingerprints select the instructed qwen3 defaults")
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
