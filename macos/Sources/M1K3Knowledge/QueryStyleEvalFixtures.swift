//
//  QueryStyleEvalFixtures.swift
//  M1K3Knowledge
//
//  Fixtures + pure report for the KEYWORD-QUERY GAP instrument
//  (M1K3_SELFTEST_KEYEVAL). Measured live 2026-07-08: full natural-language
//  QUESTIONS hit their target memory at rank #1 while bare KEYWORD queries
//  ("Golden Gate milestone") drift below the retrieval floors — the
//  no-instruct-prefix qwen3 embedder is symmetric, so keyword-string↔prose
//  under-aligns. The candidate fix is Qwen3-Embedding's official asymmetric
//  query instruction (`EmbeddingText.forQuery`); this harness measures BOTH
//  arms (bare vs instructed query) against the same production-composed
//  targets in one run, so the floor decision is derived from data, not vibes.
//
//  Two-sided by design (the challenger's flip): an instruction can lift NOISE
//  cosines as much as signal, and the memory floor's lowest true positive sat
//  0.003 above the bar — so the report always shows the noise ceiling and the
//  pooled positive floor together, per arm. "Floors unchanged" is the outcome
//  that needs justifying, not the default.
//
//  Fixtures + formatter are pure (unit-tested); the embedding pass is
//  verify-by-launch (metallib wall).
//
//  Signed: Kev + claude-fable-5, 2026-07-09, Confidence 0.85 (probe set seeded
//  from the live 07-08 misses + keyword-ified MEMEVAL positives; extend as
//  real keyword misses surface). Prior: Unknown
//

import Foundation

public enum QueryStyleEvalFixtures {
    /// One retrieval case, asked two ways. `title`/`content` compose through
    /// `EmbeddingText.forChunk` exactly as production stores the target
    /// (memory facts set title == content and therefore embed bare).
    public struct Probe: Sendable {
        public let keyword: String
        public let question: String
        public let title: String
        public let content: String

        public init(keyword: String, question: String, title: String, content: String) {
            self.keyword = keyword
            self.question = question
            self.title = title
            self.content = content
        }
    }

    /// A keyword-style query that must NOT match its (unrelated) target —
    /// the noise ceiling for the keyword register, per arm.
    public struct NoisePair: Sendable {
        public let keyword: String
        public let title: String
        public let content: String

        public init(keyword: String, title: String, content: String) {
            self.keyword = keyword
            self.title = title
            self.content = content
        }
    }

    /// A memory-fact probe: facts are their own titles and embed bare.
    private static func fact(_ keyword: String, _ question: String, _ memory: String) -> Probe {
        Probe(keyword: keyword, question: question, title: memory, content: memory)
    }

    /// The keyword/question pairs. The first probe is the live 2026-07-08
    /// failure verbatim (question hit #1, keyword missed); the fact probes are
    /// keyword-ified MEMEVAL positives so the two instruments stay comparable.
    ///
    /// The Golden Gate probe's keyword appears VERBATIM in its target title —
    /// deliberately not "too easy": the production store carried that exact
    /// title-prefixed text on 07-08 and the bare keyword query still missed
    /// (a dense symmetric encoder doesn't reward literal token overlap the way
    /// sparse retrieval would). Maximum-overlap-and-still-missing is the
    /// hardest-mode evidence for the instruction, not a softball.
    public static let probes: [Probe] = [
        Probe(
            keyword: "Golden Gate milestone",
            question: "Do you remember the Golden Gate milestone from July 2026?",
            title: "Golden Gate milestone — July 2026",
            content: "The full-graph macOS 27 beta build passed end-to-end — the Golden Gate "
                + "derisk milestone: every module compiled against the new LanguageModel "
                + "surface behind the FoundationModels compile gate."
        ),
        Probe(
            keyword: "TestFlight external submission",
            question: "When was the first external TestFlight build submitted for review?",
            title: "First external TestFlight submission",
            content: "M1K3's first external TestFlight build (135) was submitted for "
                + "Beta App Review on the morning of the 8th of July 2026."
        ),
        Probe(
            keyword: "attention mechanism",
            question: "how does attention work?",
            title: "Attention Is All You Need",
            content: "An attention function maps a query and a set of key-value pairs to an "
                + "output, computed as a weighted sum of the values, where the weight of each "
                + "value comes from a compatibility function of the query with the corresponding key."
        ),
        fact("sister name", "what's my sister's name?", "Kev's sister is called Aoife."),
        fact("coffee order", "how do I take my coffee?", "Kev drinks his coffee black, no sugar."),
        fact("company name", "what's the name of my company?", "Kev's company is called Round Tower."),
        fact(
            "database decision", "which database library did we pick?",
            "The user decided to use GRDB over Core Data for persistence."
        ),
        fact("football day", "what day do I play football?", "Kev plays five-a-side football on Thursdays."),
        fact("allergy", "what am I allergic to?", "The user is allergic to penicillin."),
        fact("editor setup", "what editor setup do I use?", "The user's favourite editor is Xcode with Vim bindings."),
    ]

    /// Keyword-register noise: terse queries against unrelated in-set-style
    /// targets (the 06-13 leaker vocabulary, keyword-ified). These cosines are
    /// the ceiling the floors must stay above — in BOTH arms.
    public static let noise: [NoisePair] = [
        NoisePair(
            keyword: "sourdough starter ratio",
            title: "Golden Gate milestone — July 2026",
            content: "The full-graph macOS 27 beta build passed end-to-end — the Golden Gate "
                + "derisk milestone: every module compiled against the new LanguageModel "
                + "surface behind the FoundationModels compile gate."
        ),
        NoisePair(
            keyword: "apple tree pruning",
            title: "Attention Is All You Need",
            content: "An attention function maps a query and a set of key-value pairs to an "
                + "output, computed as a weighted sum of the values."
        ),
        NoisePair(
            keyword: "css div centering",
            title: "Kev's sister is called Aoife.",
            content: "Kev's sister is called Aoife."
        ),
        NoisePair(
            keyword: "high tide Cork",
            title: "The user decided to use GRDB over Core Data for persistence.",
            content: "The user decided to use GRDB over Core Data for persistence."
        ),
        NoisePair(
            keyword: "pasta recipe",
            title: "First external TestFlight submission",
            content: "M1K3's first external TestFlight build (135) was submitted for "
                + "Beta App Review on the morning of the 8th of July 2026."
        ),
        NoisePair(
            keyword: "javascript framework choice",
            title: "Kev drinks his coffee black, no sugar.",
            content: "Kev drinks his coffee black, no sugar."
        ),
    ]
}

/// Pure formatter for the two-arm query-style report. Given each arm's
/// measured cosines (keyword→target, question→target, keyword-noise→target),
/// render the distributions, the keyword→question gap, the separation margin,
/// per-floor hit/leak counts, and — where separation is clean — a suggested
/// floor. Two arms get a head-to-head delta line.
public enum QueryStyleEvalReport {
    public struct Arm: Sendable {
        public let label: String
        public let keyword: [Float]
        public let question: [Float]
        public let noise: [Float]

        public init(label: String, keyword: [Float], question: [Float], noise: [Float]) {
            self.label = label
            self.keyword = keyword
            self.question = question
            self.noise = noise
        }
    }

    /// Margin = lowest POOLED positive (keyword AND question — both registers
    /// must clear a production floor) minus highest noise cosine. Positive =
    /// a dead-zone the floor can sit in; nil when a class is empty.
    public static func margin(_ arm: Arm) -> Float? {
        let positives = arm.keyword + arm.question
        guard let floor = positives.min(), let ceiling = arm.noise.max() else { return nil }
        return floor - ceiling
    }

    public static func render(_ arms: [Arm], floors: [Float]) -> String {
        var lines: [String] = []
        for arm in arms {
            lines.append("[\(arm.label)]")
            lines.append("  keyword→target:  \(SeparationEvalReport.summary(arm.keyword))")
            lines.append("  question→target: \(SeparationEvalReport.summary(arm.question))")
            lines.append("  noise→target:    \(SeparationEvalReport.summary(arm.noise))")
            if let gap = gap(arm) {
                lines.append(String(format: "  keyword→question gap: %.3f", gap))
            }
            if let m = margin(arm) {
                let verdict = m > 0 ? "clean dead-zone" : "OVERLAP — noise band swallows signal"
                lines.append(String(format: "  margin (positive floor − noise ceiling): %.3f (%@)", m, verdict))
            }
            for floor in floors {
                lines.append(String(
                    format: "  floor %.3f: keyword %d/%d · question %d/%d · noise leaks %d",
                    floor,
                    arm.keyword.count(where: { $0 >= floor }), arm.keyword.count,
                    arm.question.count(where: { $0 >= floor }), arm.question.count,
                    arm.noise.count(where: { $0 >= floor })
                ))
            }
            lines.append(contentsOf: suggestion(arm))
        }
        lines.append(contentsOf: headToHead(arms))
        return lines.joined(separator: "\n")
    }

    /// Mean question cosine minus mean keyword cosine — the gap the
    /// instruction is supposed to close. Nil when either register is empty.
    static func gap(_ arm: Arm) -> Float? {
        guard !arm.keyword.isEmpty, !arm.question.isEmpty else { return nil }
        let keywordMean = arm.keyword.reduce(0, +) / Float(arm.keyword.count)
        let questionMean = arm.question.reduce(0, +) / Float(arm.question.count)
        return questionMean - keywordMean
    }

    private static func suggestion(_ arm: Arm) -> [String] {
        let positives = arm.keyword + arm.question
        guard let posMin = positives.min(), let noiseMax = arm.noise.max() else { return [] }
        if posMin > noiseMax {
            return [String(
                format: "  suggested floor: %.3f (midpoint: noise max %.3f < positive min %.3f)",
                (posMin + noiseMax) / 2, noiseMax, posMin
            )]
        }
        let overlap = positives.count(where: { $0 <= noiseMax })
        return [String(
            format: "  OVERLAP: %d positive(s) at or below noise max %.3f — pick the floor that loses fewest",
            overlap, noiseMax
        )]
    }

    private static func headToHead(_ arms: [Arm]) -> [String] {
        guard arms.count == 2 else { return [] }
        let a = arms[0], b = arms[1]
        guard !a.keyword.isEmpty, !b.keyword.isEmpty,
              let aNoiseMax = a.noise.max(), let bNoiseMax = b.noise.max(),
              let aMargin = margin(a), let bMargin = margin(b)
        else { return [] }
        let aKeywordMean = a.keyword.reduce(0, +) / Float(a.keyword.count)
        let bKeywordMean = b.keyword.reduce(0, +) / Float(b.keyword.count)
        return [String(
            format: "head-to-head (%@ vs %@): keyword mean %+.3f · noise ceiling %+.3f · margin %+.3f",
            b.label, a.label,
            bKeywordMean - aKeywordMean, bNoiseMax - aNoiseMax, bMargin - aMargin
        )]
    }
}
