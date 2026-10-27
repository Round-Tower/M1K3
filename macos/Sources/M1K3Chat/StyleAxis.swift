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
//  Review: Kev + claude-opus-5.5, 2026-10-27 — `inSaidOrder`: one slice's style facts follow the user's turns, so
//  "newest" means said last (exit-path distillation sends a whole chat as one slice). A tie keeps the distiller's
//  order: "not short, long" in one turn cannot be placed by words alone. Confidence 0.8.
//  Review: same day — `unplaced` says why a style fact has no axis (scoped, or unknown to the table), for the
//  coordinator's count-only `.notice` line: the field signal for the cue table's recall.
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

    /// Why a style fact takes no part in the axis supersede.
    public enum Unplaced: Sendable, Hashable {
        /// It qualifies a standing ask ("…when driving"): no axis on purpose.
        case scoped
        /// No cue matched: the cue table's recall gap, counted in the field.
        case unknown
    }

    /// Why `fact` has no axis, or nil when it has one.
    public static func unplaced(_ fact: String) -> Unplaced? {
        if matches(scopeCues, in: StyleAskFence.normalised(fact)) { return .scoped }
        return axes(of: fact).isEmpty ? .unknown : nil
    }

    // MARK: - Said order

    /// Words every style fact is about, so they place nothing: "answers" is in most asks.
    static let formWords: Set<String> = ["answer", "answers", "response", "responses", "reply", "replies"]

    /// `facts` with its style facts reordered by when the user SAID them: the last user turn holding
    /// a distinctive word of each (its content tokens, minus StyleAskFence's scaffold and `formWords`).
    /// Exit-path distillation sends a whole chat as one slice, so "short… later, actually long" comes
    /// back together, in whatever order the distiller wrote it, and the store treats the later write
    /// as the newer ask. Only the style slots move; a tie, or a fact no turn places (it goes first),
    /// keeps the distiller's order.
    public static func inSaidOrder(
        _ facts: [DistilledFact],
        userTurns: [String],
        selfNames: DistillationAttribution.UserNames = .none
    ) -> [DistilledFact] {
        let slots = facts.indices.filter { facts[$0].kind == .style }
        guard slots.count > 1 else { return facts }
        let turnTokens = userTurns.map { DistillationAttribution.contentTokens(in: $0, selfNames: selfNames) }
        func saidAt(_ fact: DistilledFact) -> Int {
            let distinctive = DistillationAttribution.contentTokens(in: fact.text, selfNames: selfNames)
                .subtracting(StyleAskFence.scaffoldTokens)
                .subtracting(formWords)
            return turnTokens.lastIndex { !$0.isDisjoint(with: distinctive) } ?? -1
        }
        let ordered = slots.enumerated()
            .map { (offset: $0.offset, fact: facts[$0.element], said: saidAt(facts[$0.element])) }
            .sorted { ($0.said, $0.offset) < ($1.said, $1.offset) }
        var result = facts
        for (slot, entry) in zip(slots, ordered) {
            result[slot] = entry.fact
        }
        return result
    }

    private static func matches(_ fragments: [String], in text: String) -> Bool {
        let pattern = #"\b(?:"# + fragments.joined(separator: "|") + #")\b"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}
