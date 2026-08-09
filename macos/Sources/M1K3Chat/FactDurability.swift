//
//  FactDurability.swift
//  M1K3Chat
//
//  A memory store that only ever GROWS gets worse every day. The distiller had
//  no notion of durability: it filed "Kev lives in Cork" and "Kev is currently
//  drinking" as the same kind of thing, for ever. On 2026-08-09 the real facts
//  were measurably losing retrieval to the junk — "where does the user live"
//  surfaced "the user is using a computer for the conversation" while three
//  true Cork rows sat below it.
//
//  MEASURED, same day, over the live store (MEMSTAT durability census): 36 of
//  321 memory rows, 11%, are transient — 28 turn-summaries and 8 moment-states.
//  That is a FLOOR (the census classifies truncated titles), and it is a good
//  deal lower than the "about half" I guessed from reading the listing. Worth
//  saying plainly: this gate fixes 11%, not the whole problem. The larger
//  remainder is rows that are durable in SHAPE but near-worthless in content
//  ("the user is interested in engineering pursuits"), which no write-time
//  pattern can catch — that wants a value judgement, and it is the next piece
//  of work, not this one.
//
//  The failure is upstream of retrieval: fed a transcript, a small model
//  SUMMARISES THE CONVERSATION when it was asked to extract facts about a
//  person. "The user asked for tips on keeping curry fresh" is a true sentence
//  about a turn and a worthless sentence about Kev.
//
//  So this is a write-time gate, the same shape as `MemoryFactValidator`: the
//  prompt asks for durable facts, and this is the deterministic backstop for
//  when the model obliges with a diary entry instead. Deliberately
//  HIGH-PRECISION — a wrongly-dropped fact is invisible, so every rule is
//  anchored to a phrase that cannot plausibly appear in a standing fact, and
//  every rule below was derived from a row actually found in the live store.
//
//  v1 DROPS transient facts rather than storing them with an expiry. Expiry is
//  the richer design and needs a schema column; dropping needs nothing, stops
//  the bleeding immediately, and loses nothing that was worth keeping. The seam
//  is here if `.transient` should later mean "store with a half-life".
//
//  Signed: Kev + claude-opus-5, 2026-08-09, Confidence 0.85 (rules derived from
//  a measured audit of ~300 live rows, with the near-miss guards pinned in the
//  same suite; the precision claim rests on those fixtures, and real-world
//  wordings will be broader than any list I can write today — expect to add
//  cases, and never widen a rule without a fixture that demanded it).
//  Prior: Unknown
//

import Foundation

/// Why a distilled "fact" is not worth keeping for ever.
public enum TransientFactReason: String, Sendable, Equatable, CaseIterable {
    /// Describes a TURN rather than the person: "the user asked for tips on
    /// curry", "the conversation takes place at a bar". True, and useless as a
    /// memory — the durable fact, if there was one, is a different sentence.
    case speechAct
    /// True for minutes and stored for ever: "Kev is currently drinking",
    /// "Kev is halfway through a bottle of Red Bull".
    case momentState
}

public enum FactDurability: Sendable, Equatable {
    case durable
    case transient(TransientFactReason)
}

public enum FactDurabilityPolicy {
    /// Markers that pin a sentence to the moment it was written. Each is
    /// multi-character and word-bounded so it cannot ride a longer word — the
    /// trap here is "currently" vs "current events", which a naive `contains`
    /// gets wrong and which is pinned by test.
    static let momentMarkers = [
        "currently", "right now", "at the moment", "at present", "just now",
        "halfway through", "is about to", "for the time being", "at the minute",
        "this morning", "this afternoon", "this evening", "tonight",
    ]

    /// Speech-act verbs: the sentence reports something SAID this session.
    /// Deliberately excludes "recommends", "suggests", "prefers" and "plans" —
    /// those carry content that survives the turn, and dropping them would cost
    /// real facts (pinned as near-misses).
    static let speechVerbs = [
        "asked", "asks", "asking", "requested", "requests", "requesting",
        "inquired", "inquire", "enquired", "enquire", "mentions", "mentioned",
        "replied", "responded", "respond", "answered", "greeted",
    ]

    /// The verb must belong to the USER, immediately (auxiliaries and a
    /// "decided to" aside). A bare verb search is not precise enough: "Kev's
    /// sister asks him for tech advice every Christmas" is a perfectly durable
    /// fact that happens to contain "asks". Requiring whitespace after the
    /// subject is what separates it — "Kev's" is followed by an apostrophe, so
    /// the sister's asking never reads as Kev's turn.
    static let speechActPattern: String = {
        let subject = "(the user|user|kev|they)"
        let auxiliary = "(has |had |have |is |was |had not |has not )?"
        let framing = "(decided to |wanted to |went on to |began to )?"
        return "\\b\(subject)\\s+\(auxiliary)\(framing)(\(speechVerbs.joined(separator: "|")))\\b"
    }()

    /// The conversation, the assistant, and the session as SUBJECT MATTER.
    /// A standing fact about a person does not mention the chat it was said in.
    /// `an assistant` / `the assistant` are anchored with their article so
    /// "the user is a research assistant" — a real false-positive guard in the
    /// role-fence suite — survives untouched.
    static let metaPhrases = [
        "the conversation", "this conversation", "the assistant", "an assistant",
        "ai assistant", "for the conversation", "has not yet provided",
    ]

    public static func classify(_ fact: String) -> FactDurability {
        let text = fact.lowercased()

        // Meta and speech acts first: "the user is currently asking about X" is
        // better described as a turn than as a moment, and the turn reading is
        // the more useful log line.
        if metaPhrases.contains(where: { text.contains($0) }) {
            return .transient(.speechAct)
        }
        if text.range(of: speechActPattern, options: [.regularExpression]) != nil {
            return .transient(.speechAct)
        }
        if momentMarkers.contains(where: { containsWord($0, in: text) }) {
            return .transient(.momentState)
        }
        return .durable
    }

    public static func isDurable(_ fact: String) -> Bool {
        classify(fact) == .durable
    }

    /// Word-boundary containment, which is the whole guard for the moment
    /// markers: a plain `contains("currently")` also fires on nothing, but a
    /// plain `contains("current")` would eat "the user is interested in current
    /// events" — a real durable row. ICU's `\b` is the \w-based boundary, which
    /// is what's wanted here (marker words carry no apostrophes).
    private static func containsWord(_ needle: String, in haystack: String) -> Bool {
        haystack.range(
            of: "\\b\(NSRegularExpression.escapedPattern(for: needle))\\b",
            options: [.regularExpression]
        ) != nil
    }
}
