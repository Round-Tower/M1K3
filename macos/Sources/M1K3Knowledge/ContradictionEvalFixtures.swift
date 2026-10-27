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
//  Review: Kev + claude-opus-5.5, 2026-10-27 — #699: `styleCorrections`, a stated answer style flipped on
//  one axis (length, format, tone, order), phrased as the distiller writes style facts. MEMSTAT reads
//  where they land against the live bar: at or over it the correction supersedes at write time; below
//  it both rows stay live and the persona's newest-first order is what the model reads. The report gains
//  that one line only when the class is measured. Confidence 0.8 (hand-curated; extend from real rows).
//  Review: Kev + claude-opus-5.5, 2026-10-27 — #699 MEMSTAT rewire: `styleCompatibles`, asks on DIFFERENT axes (and
//  one scoped ask) that must both stay live under the axis supersede, so the on-device probe can show the fix
//  retires corrections without eating neighbours; the report counts the ones the twin bar would retire.
//  Confidence 0.85.
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

    /// #699: a stated answer style the user later CORRECTS on one axis. A supersede
    /// is the right outcome; below the bar both rows stay live and the persona's
    /// newest-first style line is all that keeps the correction on top. Phrased the
    /// way the distiller prompt asks for a style fact ("prefers"/"wants").
    public static let styleCorrections: [Pair] = [
        .init(prior: "The user prefers short answers.", revision: "The user prefers long, detailed answers."),
        .init(prior: "The user wants no bullet lists.", revision: "The user wants answers as bullet lists."),
        .init(prior: "The user prefers answers under three sentences.",
              revision: "The user prefers answers of a full paragraph."),
        .init(prior: "The user prefers a casual tone.", revision: "The user prefers a formal tone."),
        .init(prior: "The user wants the code before the explanation.",
              revision: "The user wants the explanation before the code."),
        .init(prior: "The user prefers plain words without jargon.",
              revision: "The user prefers precise technical terms."),
        .init(prior: "The user wants no emoji in answers.", revision: "The user wants emoji in answers."),
        .init(prior: "The user prefers answers that skip the preamble.",
              revision: "The user prefers answers that set the scene first."),
    ]

    /// #699: two stated asks on DIFFERENT axes (one of them scoped to a case), both true
    /// together. The style axis supersede (StyleAxis) must leave both live, either way
    /// round; StyleAxisSupersedeTests pins that and MEMSTAT reads it with the real embedder.
    public static let styleCompatibles: [Pair] = [
        .init(prior: "The user prefers short answers.", revision: "The user wants no emoji in answers."),
        .init(prior: "The user prefers a casual tone.", revision: "The user wants no bullet lists."),
        .init(prior: "The user prefers plain words without jargon.",
              revision: "The user wants the code before the explanation."),
        .init(prior: "The user prefers answers that skip the preamble.", revision: "The user prefers a formal tone."),
        .init(prior: "The user wants no tables.", revision: "The user wants headings in long answers."),
        .init(prior: "The user wants no jokes.", revision: "The user prefers a casual tone."),
        .init(prior: "The user wants a list of sources at the end.", revision: "The user wants no bullet lists."),
        .init(prior: "The user wants to be asked before the assistant searches the web.",
              revision: "The user wants the code before the explanation."),
        .init(prior: "The user wants answers in plain text.", revision: "The user prefers plain words without jargon."),
        .init(prior: "The user prefers concise answers.", revision: "The user wants the answer first."),
        .init(prior: "The user wants a detailed answer for code reviews.", revision: "The user prefers short answers."),
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
        styleCorrections: [Float] = [],
        styleCompatibles: [Float] = [],
        dedupeBar: Float
    ) -> String {
        let classes: [(label: String, verb: String, scores: [Float])] = [
            ("contradictions", "eaten as duplicates", contradictions),
            ("compatibles", "would be wrongly eaten", compatibles),
            ("restatements", "correctly eaten", restatements),
            // #699: since Tier 2 a ≥ bar twin is superseded, which is what a style correction wants.
            ("style corrections", "superseded at write time", styleCorrections),
            // Asks on different axes: at the bar the kind-blind twin path would retire one.
            ("style compatibles", "wrongly retired at the twin bar", styleCompatibles),
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
