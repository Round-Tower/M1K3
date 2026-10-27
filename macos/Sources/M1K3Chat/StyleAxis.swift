//
//  StyleAxis.swift
//  M1K3Chat
//
//  #699: which axis of an answer a stated style fact is about (length, lists, tone…), so a
//  style CORRECTION retires the ask it corrects. MEMSTAT (docs/evals/2026-10-27-memstat-style.txt)
//  measured the twin bar alone: 7 of 8 style corrections sit under EmbeddingGemma's 0.95 (and
//  that bar must never drop: an eaten contradiction is a lost correction), so both rows stayed
//  live and the style line said "The user prefers long, detailed answers. The user prefers
//  short answers." The axis is a second key, for `.style` rows only: a new style retires the
//  NEWEST live style whose axes are a non-empty subset of its own (the coordinator does the
//  write, through the Tier-2 supersede, so lineage, revive and forget all hold).
//
//  The classifier reads a DISTILLED fact ("The user prefers short answers."), never a turn:
//  lowercased, curly apostrophes straightened, word-bounded cues. Polarity is ignored on
//  purpose ("no emoji" and "emoji" share an axis: one corrects the other). Fail-safe by
//  construction: a fact on no known axis has the empty set, which never retires a row and is
//  never retired. Left out on purpose, so they read as unknown: a bare "simple"/"plain",
//  "fluff"/"filler"/"waffle", "step-by-step", languages, a bare "first" or "before" (order
//  needs PART before/after PART). A SCOPED ask ("…for code reviews", "…when driving") is the
//  empty set too: it qualifies a standing ask rather than replacing it.
//
//  Known, accepted residue (pinned in StyleAxisTests): a narrower correction leaves a wider
//  ask live ("formal tone" after "short, casual answers"); two asks on one axis that are both
//  true ("short answers" and "short sentences") retire each other.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.8 (pure and pinned; the cue table is
//  the challenger's 2026-10-27 prototype, verified on the 8 MEMSTAT corrections and 11
//  compatibles, its recall on live asks unmeasured: the coordinator counts style rows with no
//  axis as the field signal). Prior: none (new file).
//

import Foundation

public enum StyleAxis: String, CaseIterable, Sendable {
    case length, lists, tables, markup, emoji, tone, humour, technicality, opening, order

    /// The parts of an answer an ORDER ask puts one before the other.
    static let parts = "(code|explanation|explanations|example|examples|answer|summary|steps|reasoning|"
        + "conclusion|caveats?|context|background|sources)"

    /// Each axis's cues: regex fragments, matched word-bounded on the normalised fact.
    static let cues: [StyleAxis: [String]] = [
        .length: [
            "short", "shorter", "brief", "briefer", "briefly", "concise", "succinct", "terse",
            "long", "longer", "lengthy", "detailed", "more detail", "in-depth", "in depth", "thorough",
            "comprehensive", "verbose", "wordy", "one-liners?", "sentences?", "paragraphs?", #"\d+ words"#,
            "word count",
        ],
        // "list of" asks for content ("a list of sources"), not for list formatting.
        .lists: ["bullets?", "bulleted", "bullet points?", "lists?(?! of)", "numbered", "point form"],
        .tables: ["tables?"],
        .markup: ["markdown", "headings?", "headers?", "bold", "italics", "plain text", "formatting"],
        .emoji: ["emoji", "emojis", "emoticons?", "smileys?"],
        .tone: [
            "tone", "casual", "casually", "formal", "formally", "informal", "professional", "chatty", "conversational",
        ],
        .humour: ["jokes?", "humou?r", "sarcasm", "sarcastic", "banter", "slagging", "puns?", "witty", "snarky?"],
        .technicality: [
            "jargon", "technical", "technically", "terminology", "layman'?s?", "plain (english|language|words)",
            "simple (words|language)", "everyday words", "eli5", "explain like", "acronyms?",
        ],
        .opening: [
            "preamble", "intros?", "introductions?", "set the scene", "scene-setting", "(get|straight) to the point",
            "lead-in", "warm-up", "(answer|context|background|bottom line) first", "lead with", "pleasantries",
            "throat-clearing",
        ],
        .order: [parts + " (before|after) (the )?" + parts],
    ]

    /// A fact carrying one of these qualifies a standing ask rather than replacing it.
    static let scopeCues = ["when", "if", "unless", "for", "during", "except"]

    /// The axes `fact` is about; empty when it is on none, or scoped.
    public static func axes(of fact: String) -> Set<StyleAxis> {
        let text = StyleAskFence.normalised(fact)
        guard !matches(scopeCues, in: text) else { return [] }
        return Set(allCases.filter { matches(cues[$0] ?? [], in: text) })
    }

    /// Whether a new style ask `new` retires the live ask `old`: `old` is on at least one
    /// known axis, and `new` covers every one of them.
    public static func retires(_ old: String, for new: String) -> Bool {
        let oldAxes = axes(of: old)
        return !oldAxes.isEmpty && oldAxes.isSubset(of: axes(of: new))
    }

    /// The live style `new` retires: the first of `live` (newest first) that it covers and that is
    /// not `new` itself (the same normalised identity). One victim per write, by design.
    public static func newestRetired(by new: String, amongNewestFirst live: [String]) -> String? {
        let identity = MemoryFactNormalizer.normalize(new)
        let newAxes = axes(of: new)
        guard !newAxes.isEmpty else { return nil }
        return live.first { old in
            guard MemoryFactNormalizer.normalize(old) != identity else { return false }
            let oldAxes = axes(of: old)
            return !oldAxes.isEmpty && oldAxes.isSubset(of: newAxes)
        }
    }

    private static func matches(_ fragments: [String], in text: String) -> Bool {
        let pattern = #"\b(?:"# + fragments.joined(separator: "|") + #")\b"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}
