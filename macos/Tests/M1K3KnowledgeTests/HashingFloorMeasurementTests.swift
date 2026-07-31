//
//  HashingFloorMeasurementTests.swift
//  M1K3KnowledgeTests
//
//  The hashing-arm floor derivation, as a CI-runnable measurement — the
//  "hashing-arm KEYEVAL bracket" GroundingGate's 07-09 caveat named.
//  HashingEmbeddingService is deterministic and pure, so unlike the qwen
//  floors (on-device SelfTest, metallib wall) this measurement runs in every
//  `swift test`: it re-derives the MEMEVAL/ABSEP distributions with the real
//  hashing embedder over the SAME fixture sets that set the qwen floors, and
//  pins `EmbedderFloors.hashing` against them. If the hashing algorithm (or
//  a fixture set) changes shape, these assertions — not a stale comment —
//  say the floors need re-deriving.
//
//  Measured 2026-07-31 (dimension 256, bare queries — hashing takes the
//  symmetric embedQuery default, mirroring production):
//  - MEMEVAL positives 0.0–0.589 (four at 0.0: zero-token-overlap synonym
//    pairs, unsavable by any floor), negatives ceiling 0.408 → NO clean cut;
//    recall-first picks 0.10 (keeps 18/22 vs 6/22 under the shared qwen bar).
//  - ABSEP in-domain 0.045–0.490, off-domain ceiling 0.304 → chunk floor
//    0.35 = dead-band centre between the noise ceiling and the surviving
//    signal floor (0.402).
//
//  Signed: Kev + claude-fable-5, 2026-07-31, Confidence 0.85 (deterministic
//  measurement over hand-curated fixture sets — the sets are the limit, not
//  the arithmetic; extend them as real iOS recall misses surface).
//  Prior: Unknown
//

import M1K3Knowledge
import Testing

struct HashingFloorMeasurementTests {
    private struct Distributions {
        let memPositives: [Float]
        let memNegatives: [Float]
        let inDomain: [Float]
        let offDomain: [Float]
    }

    private func measure() async throws -> Distributions {
        let embedder = HashingEmbeddingService()

        func cosine(query: String, content: String) async throws -> Float {
            // Production path: queries via embedQuery (hashing's symmetric
            // default — no instruction), content via embed.
            let q = try await embedder.embedQuery(query)
            let c = try await embedder.embed(content)
            return VectorMath.cosineSimilarity(q, c)
        }

        var memPos: [Float] = []
        for pair in MemoryEvalFixtures.positives {
            try await memPos.append(cosine(query: pair.query, content: pair.memory))
        }
        var memNeg: [Float] = []
        for pair in MemoryEvalFixtures.negatives {
            try await memNeg.append(cosine(query: pair.query, content: pair.memory))
        }
        var inDomain: [Float] = []
        for pair in SeparationEvalFixtures.inDomain {
            try await inDomain.append(cosine(query: pair.query, content: pair.document))
        }
        var offDomain: [Float] = []
        for pair in SeparationEvalFixtures.offDomain {
            try await offDomain.append(cosine(query: pair.query, content: pair.document))
        }
        return Distributions(
            memPositives: memPos, memNegatives: memNeg,
            inDomain: inDomain, offDomain: offDomain
        )
    }

    @Test("the memory floor is recall-first: ≥18/22 true recalls, vs ≤6/22 under the shared qwen bar")
    func memoryFloorRecall() async throws {
        let d = try await measure()
        let floors = EmbedderFloors.hashing
        let recalled = d.memPositives.count { $0 >= floors.memory }
        #expect(recalled >= 18, "hashing memory floor \(floors.memory) recalls \(recalled)/22")

        // The motivating regression, pinned as data: the qwen bar on the
        // hashing cone silently breaks the "I'll remember" promise.
        let underShared = d.memPositives.count { $0 >= EmbedderFloors.qwen3Instructed.memory }
        #expect(underShared <= 6, "shared qwen bar unexpectedly recalls \(underShared)/22 — re-derive")
    }

    @Test("the memory floor still clears the zero-overlap noise band")
    func memoryFloorGates() async throws {
        let d = try await measure()
        // Half the negatives are literal 0.0 (no shared tokens); the floor
        // must at least keep those out — the honest bar an overlapping
        // distribution allows.
        let admitted = d.memNegatives.count { $0 >= EmbedderFloors.hashing.memory }
        #expect(admitted <= 6, "hashing memory floor admits \(admitted)/11 negatives — distribution moved")
    }

    @Test("the chunk floor sits in the measured dead band: above the noise ceiling, below the surviving signal")
    func chunkFloorDeadBand() async throws {
        let d = try await measure()
        let floors = EmbedderFloors.hashing
        let noiseCeiling = try #require(d.offDomain.max())
        #expect(floors.chunk > noiseCeiling, "chunk floor \(floors.chunk) under noise ceiling \(noiseCeiling)")
        // The weakest in-domain hit ABOVE the noise ceiling must still clear —
        // hits below the ceiling are unreachable by construction.
        let survivingSignalFloor = try #require(d.inDomain.filter { $0 > noiseCeiling }.min())
        #expect(floors.chunk < survivingSignalFloor,
                "chunk floor \(floors.chunk) gates real signal at \(survivingSignalFloor)")
    }
}
