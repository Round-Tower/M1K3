//
//  ContradictionEvalTests.swift
//  M1K3KnowledgeTests
//
//  Tier-0 dream-cycle probe fixtures (scratch/dream-cycle/SPEC.md): three
//  hand-authored classes — restatement (the dedupe SHOULD eat), contradiction
//  (the Dublin/Ardmore shape — must NOT be eaten), compatible same-subject
//  (must NOT be eaten OR superseded). The renderer is pure and pinned here;
//  only the embedding pass is verify-by-launch (MEMSTAT arm).
//
//  Signed: Kev + claude-fable-5, 2026-07-30, Confidence 0.9. Prior:
//  MemoryEvalFixtures (Kev + claude-fable-5).
//  Review: Kev + claude-opus-5.5, 2026-10-27 — #699: the style-correction class (a stated answer style
//  flipped on one axis) is well-formed and reports how many corrections the bar supersedes at write time.
//  Confidence 0.85.
//

@testable import M1K3Knowledge
import Testing

struct ContradictionEvalFixtureTests {
    @Test("each class carries enough pairs to read a distribution")
    func classSizes() {
        #expect(ContradictionEvalFixtures.contradictions.count >= 10)
        #expect(ContradictionEvalFixtures.compatibles.count >= 10)
        #expect(ContradictionEvalFixtures.restatements.count >= 5)
    }

    @Test("every pair changes the text — prior and revision never identical")
    func pairsAreDistinct() {
        let all = ContradictionEvalFixtures.contradictions
            + ContradictionEvalFixtures.compatibles
            + ContradictionEvalFixtures.restatements
            + ContradictionEvalFixtures.styleCorrections
        #expect(all.allSatisfy { $0.prior != $0.revision })
    }

    @Test("#699: style corrections are stated preferences the distiller would write, none borrowed from another class")
    func styleCorrectionsAreWellFormed() {
        let pairs = ContradictionEvalFixtures.styleCorrections
        #expect(pairs.count >= 8)
        // Phrased the way the distiller prompt asks for a style fact ("prefers"/"wants").
        for text in pairs.flatMap({ [$0.prior, $0.revision] }) {
            #expect(text.hasPrefix("The user prefers ") || text.hasPrefix("The user wants "), "\(text)")
            #expect(!text.lowercased().contains("assistant"), "\(text)")
        }
        let others = ContradictionEvalFixtures.contradictions
            + ContradictionEvalFixtures.compatibles
            + ContradictionEvalFixtures.restatements
        let otherPairs = Set(others.map { $0.prior + "→" + $0.revision })
        #expect(pairs.allSatisfy { !otherPairs.contains($0.prior + "→" + $0.revision) })
        #expect(Set(pairs.map(\.prior)).count == pairs.count)
    }
}

struct ContradictionEvalReportTests {
    @Test("report places each class against the dedupe bar")
    func bandPlacement() {
        let text = ContradictionEvalReport.render(
            contradictions: [0.92, 0.85, 0.60],
            compatibles: [0.70, 0.40],
            restatements: [0.95, 0.91],
            dedupeBar: 0.90
        )
        // 1 of 3 contradictions at/above the bar → that correction gets eaten.
        #expect(text.contains("contradictions ≥ 0.90 (eaten as duplicates): 1/3"))
        #expect(text.contains("restatements ≥ 0.90 (correctly eaten): 2/2"))
        #expect(text.contains("compatibles ≥ 0.90 (would be wrongly eaten): 0/2"))
    }

    @Test("report names the mineable band population per class")
    func mineableBand() {
        let text = ContradictionEvalReport.render(
            contradictions: [0.80, 0.76, 0.60],
            compatibles: [0.78],
            restatements: [0.95],
            dedupeBar: 0.90
        )
        #expect(text.contains("contradictions in [0.75, 0.90): 2/3"))
        #expect(text.contains("compatibles in [0.75, 0.90): 1/1"))
    }

    @Test("report carries min/median/max per class")
    func distributionSummary() {
        let text = ContradictionEvalReport.render(
            contradictions: [0.60, 0.80, 0.90],
            compatibles: [0.50],
            restatements: [0.95],
            dedupeBar: 0.90
        )
        #expect(text.contains("contradictions: min 0.600 median 0.800 max 0.900"))
        #expect(text.contains("compatibles: min 0.500 median 0.500 max 0.500"))
    }

    @Test("#699: style corrections report how many the bar supersedes at write time")
    func styleCorrectionPlacement() {
        let text = ContradictionEvalReport.render(
            contradictions: [0.80],
            compatibles: [0.50],
            restatements: [0.95],
            styleCorrections: [0.96, 0.88, 0.70],
            dedupeBar: 0.95
        )
        #expect(text.contains("style corrections ≥ 0.95 (superseded at write time): 1/3"))
        #expect(text.contains("style corrections: min 0.700 median 0.880 max 0.960"))
        // No style class measured: the report reads exactly as it did before #699.
        let without = ContradictionEvalReport.render(
            contradictions: [0.80], compatibles: [0.50], restatements: [0.95], dedupeBar: 0.95
        )
        #expect(!without.contains("style corrections"))
    }

    @Test("empty classes render as unmeasured, not crash")
    func emptyClass() {
        let text = ContradictionEvalReport.render(
            contradictions: [], compatibles: [], restatements: [], dedupeBar: 0.90
        )
        #expect(text.contains("no pairs measured"))
    }
}
