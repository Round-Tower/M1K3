//
//  MemoryCosineStats.swift
//  M1K3Memory
//
//  Tier 0 of the dream-cycle plan (scratch/dream-cycle/SPEC.md): the pairwise
//  cosine census over the live memory graph. Pure math — the MEMSTAT SelfTest
//  arm feeds it real vectors on-device; unit tests feed it engineered ones.
//
//  The two bands are the decision surface for everything downstream:
//    ≥ 0.90        — the semantic-dedupe bar (MemoryDistillationCoordinator).
//                    Pairs living here were supposed to be impossible (the
//                    ingest path dedupes at the same bar); residents mean an
//                    ingestion bug, not a merge target (challenger #3).
//    [0.75, 0.90)  — the band a supersede-on-write candidate search would
//                    mine. Whether contradictions actually land here (or at
//                    ≥ 0.90, where they'd be EATEN at write time) is the
//                    question the census answers (challenger #2/#4).
//
//  n² over a personal graph (thousands of rows) is millions of dot products —
//  seconds of SIMD work, no judge involved. Fine for a measurement arm.
//
//  Signed: Kev + claude-fable-5, 2026-07-30, Confidence 0.9 (pure, test-pinned;
//  band semantics from the v2 spec). Prior: Unknown
//

import Foundation
import M1K3Knowledge // VectorMath

public enum MemoryCosineStats {
    /// The dedupe bar mirrored from MemoryDistillationCoordinator. Duplicated
    /// deliberately (no M1K3Memory→M1K3Chat dep edge exists or should); the
    /// MEMSTAT report prints both so a drift is visible in the output itself.
    public static let dedupeBar: Float = 0.90
    /// Floor of the band a write-time supersede search would mine.
    public static let mineableFloor: Float = 0.75
    /// 40 bins of width 0.05 covering [-1, 1].
    public static let binCount = 40

    public struct Report: Sendable, Equatable {
        public let vectorCount: Int
        public let pairCount: Int
        /// Histogram over [-1, 1], `binCount` bins; cosine 1.0 clamps into the
        /// last bin so the counts always total `pairCount`.
        public let binCounts: [Int]
        public let pairsAtOrAboveDedupe: Int
        public let pairsInMineableBand: Int
    }

    /// Full pairwise census. O(n²) dot products — acceptable by design for a
    /// measurement arm over a personal-scale graph.
    public static func pairwise(_ vectors: [[Float]]) -> Report {
        var bins = [Int](repeating: 0, count: binCount)
        var pairs = 0
        var dedupe = 0
        var mineable = 0
        for i in vectors.indices {
            for j in vectors.indices where j > i {
                let cosine = VectorMath.cosineSimilarity(vectors[i], vectors[j])
                pairs += 1
                bins[binIndex(for: cosine)] += 1
                if cosine >= dedupeBar {
                    dedupe += 1
                } else if cosine >= mineableFloor {
                    mineable += 1
                }
            }
        }
        return Report(
            vectorCount: vectors.count,
            pairCount: pairs,
            binCounts: bins,
            pairsAtOrAboveDedupe: dedupe,
            pairsInMineableBand: mineable
        )
    }

    /// Multi-line text report: totals, the two decision bands, and every
    /// non-empty bin (empty bins omitted so a sparse personal graph stays
    /// readable in a SelfTest log).
    public static func render(_ report: Report) -> String {
        var lines = [
            "memstat census: \(report.vectorCount) vector(s), \(report.pairCount) pair(s)",
            String(format: "  pairs ≥ %.2f: %d (dedupe band — should be structurally empty)",
                   dedupeBar, report.pairsAtOrAboveDedupe),
            String(format: "  pairs in [%.2f, %.2f): %d (mineable band)",
                   mineableFloor, dedupeBar, report.pairsInMineableBand),
        ]
        for (index, count) in report.binCounts.enumerated() where count > 0 {
            let lower = -1.0 + Float(index) * 0.05
            lines.append(String(format: "  [%+.2f, %+.2f): %d", lower, lower + 0.05, count))
        }
        return lines.joined(separator: "\n")
    }

    private static func binIndex(for cosine: Float) -> Int {
        let raw = Int(((cosine + 1) / 0.05).rounded(.down))
        return min(max(raw, 0), binCount - 1)
    }
}
