//
//  MemoryCosineStatsTests.swift
//  M1K3MemoryTests
//
//  Contract for the Tier-0 dream-cycle measurement (scratch/dream-cycle/SPEC.md):
//  a pairwise cosine census over the live memory graph. Vectors are hand-built
//  so every cosine is exact — the band assertions (≥ dedupe bar, mineable
//  [0.75, 0.90)) check arithmetic, not embedder behaviour.
//
//  Signed: Kev + claude-fable-5, 2026-07-30, Confidence 0.9 (pure math,
//  engineered fixtures). Prior: Unknown
//

@testable import M1K3Memory
import Testing

struct MemoryCosineStatsTests {
    @Test("no pairs from zero or one vector")
    func degenerateInputs() {
        #expect(MemoryCosineStats.pairwise([]).pairCount == 0)
        #expect(MemoryCosineStats.pairwise([[1, 0]]).pairCount == 0)
        #expect(MemoryCosineStats.pairwise([]).vectorCount == 0)
    }

    @Test("n vectors yield n(n-1)/2 pairs")
    func pairCounting() {
        let report = MemoryCosineStats.pairwise([[1, 0], [0, 1], [1, 1], [1, 2]])
        #expect(report.vectorCount == 4)
        #expect(report.pairCount == 6)
    }

    @Test("identical vectors land at or above the dedupe bar")
    func dedupeBand() {
        let report = MemoryCosineStats.pairwise([[3, 4], [3, 4]])
        #expect(report.pairsAtOrAboveDedupe == 1)
        #expect(report.pairsInMineableBand == 0)
    }

    @Test("a cosine-0.8 pair counts as mineable, not dedupe")
    func mineableBand() {
        // cos([1,0],[0.8,0.6]) = 0.8 exactly (‖[0.8,0.6]‖ = 1).
        let report = MemoryCosineStats.pairwise([[1, 0], [0.8, 0.6]])
        #expect(report.pairsInMineableBand == 1)
        #expect(report.pairsAtOrAboveDedupe == 0)
    }

    @Test("orthogonal pairs sit in neither band")
    func orthogonal() {
        let report = MemoryCosineStats.pairwise([[1, 0], [0, 1]])
        #expect(report.pairsAtOrAboveDedupe == 0)
        #expect(report.pairsInMineableBand == 0)
    }

    @Test("band boundaries: 0.92 is dedupe, 0.74 is neither band")
    func bandBoundaries() {
        // cos = 0.92: [1,0] vs [0.92, sqrt(1-0.8464)] — clear of the 0.90 bar.
        let above = MemoryCosineStats.pairwise([[1, 0], [0.92, 0.391_918_4]])
        #expect(above.pairsAtOrAboveDedupe == 1)
        #expect(above.pairsInMineableBand == 0)
        // cos = 0.74: just under the 0.75 mineable floor.
        let below = MemoryCosineStats.pairwise([[1, 0], [0.74, 0.672_606_9]])
        #expect(below.pairsAtOrAboveDedupe == 0)
        #expect(below.pairsInMineableBand == 0)
    }

    @Test("histogram bins cover [-1, 1] and total the pair count")
    func histogramTotals() {
        let report = MemoryCosineStats.pairwise([[1, 0], [0, 1], [-1, 0], [0.8, 0.6]])
        #expect(report.binCounts.count == 40)
        #expect(report.binCounts.reduce(0, +) == report.pairCount)
    }

    @Test("a cosine of exactly 1.0 clamps into the last bin")
    func topEdgeClamps() {
        let report = MemoryCosineStats.pairwise([[2, 0], [5, 0]])
        #expect(report.binCounts[39] == 1)
        #expect(report.binCounts.reduce(0, +) == 1)
    }

    @Test("mismatched-dimension pairs are excluded from bins and counted separately")
    func mismatchedDimensions() {
        // VectorMath scores a length mismatch as cosine 0.0 — silently binning
        // that would corrupt the census, so such pairs are quarantined instead.
        let report = MemoryCosineStats.pairwise([[1, 0], [1, 0, 0]])
        #expect(report.pairCount == 0)
        #expect(report.mismatchedPairCount == 1)
        #expect(report.binCounts.reduce(0, +) == 0)
    }

    @Test("mismatched pairs surface in the rendered report")
    func mismatchedRendered() {
        let text = MemoryCosineStats.render(MemoryCosineStats.pairwise([[1, 0], [1, 0, 0]]))
        #expect(text.contains("1 mismatched-dimension pair(s) EXCLUDED"))
    }

    @Test("render names the counts, bands, and non-empty bins")
    func renderReport() {
        let report = MemoryCosineStats.pairwise([[1, 0], [0.8, 0.6]])
        let text = MemoryCosineStats.render(report)
        #expect(text.contains("2 vector(s)"))
        #expect(text.contains("1 pair(s)"))
        #expect(text.contains("≥ 0.90: 0"))
        #expect(text.contains("[0.75, 0.90): 1"))
        // The 0.8 pair's bin row appears; empty bins are omitted.
        #expect(text.contains("0.80"))
    }
}
