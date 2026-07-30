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
        #expect(all.allSatisfy { $0.prior != $0.revision })
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

    @Test("empty classes render as unmeasured, not crash")
    func emptyClass() {
        let text = ContradictionEvalReport.render(
            contradictions: [], compatibles: [], restatements: [], dedupeBar: 0.90
        )
        #expect(text.contains("no pairs measured"))
    }
}
