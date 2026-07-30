//
//  ContradictionEvalFixtures.swift
//  M1K3Knowledge
//
//  Tier-0 dream-cycle probe pairs (scratch/dream-cycle/SPEC.md, challenger #2/#4):
//  where do CORRECTIONS land in the embedder's cosine cone, relative to the
//  ≥ 0.90 semantic-dedupe bar that silently discards "already known" facts at
//  ingest? Three hand-authored classes:
//
//    restatements   — same fact, different words. The dedupe SHOULD eat these;
//                     they calibrate where "actually identical" sits.
//    contradictions — the Dublin/Ardmore shape: one proper noun or value flips
//                     the truth. If these embed ≥ 0.90, the ingest path EATS
//                     the correction and no supersede design can ever see it.
//    compatibles    — same subject, no conflict (both facts should coexist).
//                     They bound the false-positive risk of any write-time
//                     supersede search mining the band below the bar.
//
//  The fixtures and report formatter are pure (unit-tested); the embedding
//  pass runs on-device in the MEMSTAT SelfTest arm, same doctrine as
//  MemoryEvalFixtures.
//
//  Signed: Kev + claude-fable-5, 2026-07-30, Confidence 0.85 (pair set is
//  hand-curated to the spec's shapes — extend as real eaten-corrections
//  surface). Prior: MemoryEvalFixtures (Kev + claude-fable-5).
//

import Foundation

public enum ContradictionEvalFixtures {
    public struct Pair: Sendable {
        /// The fact the store already holds.
        public let prior: String
        /// The fact a later conversation asserts.
        public let revision: String

        public init(prior: String, revision: String) {
            self.prior = prior
            self.revision = revision
        }
    }

    /// One detail flips — the revision CORRECTS the prior. Eating any of these
    /// at ingest is the finding-#2 failure: the truth silently never lands.
    public static let contradictions: [Pair] = [
        .init(prior: "Kev lives in Dublin.", revision: "Kev lives in Ardmore."),
        .init(prior: "The user's favourite editor is Vim.", revision: "The user's favourite editor is Zed."),
        .init(prior: "Kev's dog is called Bran.", revision: "Kev's dog is called Rex."),
        .init(prior: "The user works at Round Tower.", revision: "The user works at Lighthouse Labs."),
        .init(prior: "Kev drinks his coffee black.", revision: "Kev drinks his coffee with oat milk."),
        .init(prior: "The user's next release ships in March.", revision: "The user's next release ships in September."),
        .init(prior: "Kev's sister lives in Galway.", revision: "Kev's sister lives in Lisbon."),
        .init(prior: "The user prefers dark mode.", revision: "The user prefers light mode."),
        .init(prior: "Kev drives a Toyota.", revision: "Kev drives a Volvo."),
        .init(prior: "The user's standing desk is set to 110 centimetres.",
              revision: "The user's standing desk is set to 95 centimetres."),
    ]

    /// Same subject, zero conflict — both facts are true together. A supersede
    /// mechanism must never let one replace the other.
    public static let compatibles: [Pair] = [
        .init(prior: "Kev lives in Ardmore.", revision: "Kev grew up in Waterford."),
        .init(prior: "The user's dog is a collie.", revision: "The user's dog is called Bran."),
        .init(prior: "Kev works on a Mac Studio.", revision: "Kev tests on an iPhone 17 Pro."),
        .init(prior: "The user prefers metric units.", revision: "The user prefers Celsius for weather."),
        .init(prior: "Kev's sister is called Aoife.", revision: "Kev's sister works as a nurse."),
        .init(prior: "The user drinks coffee in the morning.", revision: "The user drinks tea in the evening."),
        .init(prior: "Kev is dyslexic.", revision: "Kev prefers audio summaries."),
        .init(prior: "The user plays the guitar.", revision: "The user is learning the piano."),
        .init(prior: "Kev runs on Saturday mornings.", revision: "Kev swims on Wednesday evenings."),
        .init(prior: "The user's favourite colour is green.", revision: "The user's favourite band is Fontaines D.C."),
    ]

    /// Same fact re-worded — the dedupe's legitimate prey. These calibrate the
    /// top of the cone: if restatements and contradictions overlap, no cosine
    /// bar can separate "already known" from "correction" and Tier 2 needs a
    /// judge on the one candidate pair instead of a lexical rule.
    public static let restatements: [Pair] = [
        .init(prior: "Kev's sister is called Aoife.", revision: "Aoife is Kev's sister."),
        .init(prior: "The user prefers metric units.", revision: "Metric units are the user's preference."),
        .init(prior: "Kev lives in Ardmore.", revision: "Kev's home is in Ardmore."),
        .init(prior: "The user's dog is a collie named Bran.", revision: "Bran, the user's dog, is a collie."),
        .init(prior: "Kev drinks his coffee black.", revision: "Kev takes his coffee black."),
    ]
}

/// Pure formatter for the measured cosines — band placement per class against
/// the live dedupe bar, plus min/median/max so the report reads as a
/// distribution, not a verdict.
public enum ContradictionEvalReport {
    public static func render(
        contradictions: [Float],
        compatibles: [Float],
        restatements: [Float],
        dedupeBar: Float
    ) -> String {
        let classes: [(label: String, verb: String, scores: [Float])] = [
            ("contradictions", "eaten as duplicates", contradictions),
            ("compatibles", "would be wrongly eaten", compatibles),
            ("restatements", "correctly eaten", restatements),
        ]
        guard classes.contains(where: { !$0.scores.isEmpty }) else {
            return "contradiction eval: no pairs measured"
        }
        var lines: [String] = []
        for cls in classes where !cls.scores.isEmpty {
            let sorted = cls.scores.sorted()
            let atBar = cls.scores.filter { $0 >= dedupeBar }.count
            let mineable = cls.scores.filter { $0 >= 0.75 && $0 < dedupeBar }.count
            lines.append(String(
                format: "%@: min %.3f median %.3f max %.3f",
                cls.label, sorted.first ?? 0, sorted[sorted.count / 2], sorted.last ?? 0
            ))
            lines.append(String(
                format: "  %@ ≥ %.2f (%@): %d/%d",
                cls.label, dedupeBar, cls.verb, atBar, cls.scores.count
            ))
            lines.append(String(
                format: "  %@ in [0.75, %.2f): %d/%d",
                cls.label, dedupeBar, mineable, cls.scores.count
            ))
        }
        return lines.joined(separator: "\n")
    }
}
