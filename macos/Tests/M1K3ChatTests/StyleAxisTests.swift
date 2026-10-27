//
//  StyleAxisTests.swift
//  M1K3ChatTests
//
//  #699: which axis of the answer a stated style fact is about, the rule that lets a style
//  correction retire the ask it corrects. MEMSTAT (docs/evals/2026-10-27-memstat-style.txt)
//  measured 7 of 8 style corrections under EmbeddingGemma's 0.95 twin bar, so both rows
//  stayed live and the style line read "long, detailed… short…". The axis is the second key:
//  a new style retires the newest live one whose axes it covers. Pinned here, pure: the
//  eight MEMSTAT corrections retire in BOTH directions, the eleven compatibles in neither,
//  multi-axis residue, the unknowns and the scoped asks that never take part, and every cue
//  family one by one, so a change to the table is a visible diff.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85 (pure and pinned; the cue table
//  is the challenger's prototype, its recall on live asks unmeasured). Prior: none (new file).
//

import Foundation
@testable import M1K3Chat
@testable import M1K3Knowledge
import Testing

struct StyleAxisTests {
    private func axes(_ fact: String) -> Set<StyleAxis> {
        StyleAxis.axes(of: fact)
    }

    private func retires(_ old: String, _ new: String) -> Bool {
        StyleAxis.retires(old, for: new)
    }

    // MARK: - The MEMSTAT style corrections: same axis, both directions

    @Test(
        "each MEMSTAT style correction shares one axis with its prior, and retires it either way round",
        arguments: ContradictionEvalFixtures.styleCorrections.map { ($0.prior, $0.revision) }
    )
    func correctionsRetireBothWays(prior: String, revision: String) {
        #expect(!axes(prior).isEmpty, "\(prior)")
        #expect(axes(prior) == axes(revision), "\(prior) / \(revision)")
        #expect(retires(prior, revision))
        #expect(retires(revision, prior))
    }

    @Test("the eight corrections land on the axes the table names")
    func correctionAxesArePinned() {
        let expected: [Set<StyleAxis>] = [
            [.length], [.lists], [.length], [.tone], [.order], [.technicality], [.emoji], [.opening],
        ]
        #expect(ContradictionEvalFixtures.styleCorrections.map { axes($0.prior) } == expected)
    }

    // MARK: - Compatibles: different axes, neither retires the other

    static let compatibles: [(String, String)] = [
        ("The user prefers short answers.", "The user wants no emoji in answers."),
        ("The user prefers a casual tone.", "The user wants no bullet lists."),
        ("The user prefers plain words without jargon.", "The user wants the code before the explanation."),
        ("The user prefers answers that skip the preamble.", "The user prefers a formal tone."),
        ("The user wants no tables.", "The user wants headings in long answers."),
        ("The user wants no jokes.", "The user prefers a casual tone."),
        ("The user wants a list of sources at the end.", "The user wants no bullet lists."),
        ("The user wants to be asked before the assistant searches the web.",
         "The user wants the code before the explanation."),
        ("The user wants answers in plain text.", "The user prefers plain words without jargon."),
        ("The user prefers concise answers.", "The user wants the answer first."),
        ("The user wants a detailed answer for code reviews.", "The user prefers short answers."),
        ("The user prefers metric units.", "The user prefers short answers."),
    ]

    @Test("compatible asks never retire each other, in either direction", arguments: compatibles)
    func compatiblesNeverRetire(first: String, second: String) {
        #expect(!retires(first, second), "\(first) -> \(second)")
        #expect(!retires(second, first), "\(second) -> \(first)")
    }

    // MARK: - Multi-axis: a new ask must cover every axis of the old one

    @Test("a narrower new ask leaves a wider old one live; a wider or equal one retires it")
    func multiAxisCoverage() {
        let shortCasual = "The user prefers short, casual answers."
        #expect(axes(shortCasual) == [.length, .tone])
        // Residue, pinned: "formal tone" corrects only half of "short, casual", so both stay live.
        #expect(!retires(shortCasual, "The user prefers a formal tone."))
        #expect(retires("The user prefers a formal tone.", shortCasual))
        #expect(retires(shortCasual, "The user prefers long, formal answers."))
        #expect(retires("The user wants no emoji in answers.", "The user wants answers in plain text without emoji."))
    }

    // MARK: - Unknown and scoped: the empty set, which never takes part

    @Test(
        "an ask on no known axis has none, and neither retires nor is retired",
        arguments: [
            "The user wants answers in Irish.",
            "The user wants no fluff.",
            "The user prefers simple answers.",
            "The user wants step-by-step answers.",
            "The user wants sources cited.",
            "The user wants less filler and waffle.",
        ]
    )
    func unknownAxisNeverTakesPart(fact: String) {
        #expect(axes(fact).isEmpty)
        #expect(!retires(fact, "The user prefers long, detailed, formal answers with no emoji, lists or tables."))
        #expect(!retires("The user prefers short answers.", fact))
    }

    @Test(
        "a scoped ask (when, if, unless, for, during, except) has no axis: it never retires a standing one",
        arguments: [
            "The user wants a detailed answer for code reviews.",
            "The user wants short answers when driving.",
            "The user wants bullet lists if there are steps.",
            "The user wants a formal tone unless it is a joke.",
            "The user wants long answers during planning.",
            "The user wants no emoji except in birthday messages.",
        ]
    )
    func scopedAsksHaveNoAxis(fact: String) {
        #expect(axes(fact).isEmpty)
        #expect(!retires("The user prefers short answers.", fact))
    }

    // MARK: - The rule's edges

    @Test("order needs PART before/after PART; a bare 'first' or 'before' is not an order ask")
    func orderNeedsTwoParts() {
        #expect(axes("The user wants examples after the explanation.") == [.order])
        #expect(axes("The user wants the summary before the reasoning.") == [.order])
        #expect(!axes("The user wants code first.").contains(.order))
        #expect(!axes("The user wants to be asked before the assistant searches the web.").contains(.order))
        // "answer first" is an opening ask, not an order one.
        #expect(axes("The user wants the answer first.") == [.opening])
    }

    @Test("polarity is ignored: 'no X' and 'X' share an axis")
    func polarityIgnored() {
        #expect(axes("The user wants no tables.") == axes("The user wants tables."))
        #expect(axes("The user wants no jokes.") == axes("The user wants jokes."))
    }

    @Test("cues are word-bounded and read through case and curly apostrophes")
    func cuesAreWordBounded() {
        #expect(axes("The user likes tablespoons in recipes.").isEmpty)
        #expect(axes("The user prefers longitude in degrees.").isEmpty)
        #expect(axes("The user prefers a toned-down register.").isEmpty)
        #expect(axes("The user wants Layman\u{2019}s terms.") == [.technicality])
        #expect(axes("THE USER WANTS NO EMOJI.") == [.emoji])
        // "list of" is a request for content, not for list formatting.
        #expect(axes("The user wants a list of sources at the end.").isEmpty)
    }

    @Test("every cue family names its axis", arguments: [
        ("The user prefers brief answers.", StyleAxis.length),
        ("The user wants terse, succinct replies.", .length),
        ("The user wants in-depth, thorough answers.", .length),
        ("The user wants answers under 100 words.", .length),
        ("The user wants one-liners.", .length),
        ("The user wants bulleted answers.", .lists),
        ("The user wants numbered points.", .lists),
        ("The user wants answers in point form.", .lists),
        ("The user wants tables.", .tables),
        ("The user wants no markdown.", .markup),
        ("The user wants bold key terms.", .markup),
        ("The user wants no formatting.", .markup),
        ("The user wants no emoticons or smileys.", .emoji),
        ("The user prefers a professional register.", .tone),
        ("The user prefers chatty, conversational replies.", .tone),
        ("The user wants no sarcasm.", .humour),
        ("The user enjoys puns and banter.", .humour),
        ("The user wants humour.", .humour),
        ("The user wants no acronyms.", .technicality),
        ("The user wants plain English.", .technicality),
        ("The user wants everyday words.", .technicality),
        ("The user wants answers that explain like they are five.", .technicality),
        ("The user wants no intro.", .opening),
        ("The user wants answers straight to the point.", .opening),
        ("The user wants the bottom line first.", .opening),
        ("The user wants no pleasantries.", .opening),
        ("The user wants code after the explanation.", .order),
    ])
    func cueFamilies(fact: String, axis: StyleAxis) {
        #expect(axes(fact) == [axis], "\(fact) read as \(axes(fact))")
    }

    // MARK: - The victim: the newest live style whose axes the new ask covers

    @Test("the victim is the NEWEST live style the new ask covers; an uncovered or unknown row is passed over")
    func victimIsTheNewestCovered() {
        let live = [
            "The user wants no emoji in answers.", // newest, another axis
            "The user wants answers in Irish.", // no axis
            "The user prefers short answers.", // covered
            "The user prefers brief answers.", // covered, older
        ]
        #expect(StyleAxis.newestRetired(by: "The user prefers long, detailed answers.", amongNewestFirst: live)
            == "The user prefers short answers.")
        #expect(StyleAxis.newestRetired(by: "The user prefers a formal tone.", amongNewestFirst: live) == nil)
        #expect(StyleAxis.newestRetired(by: "The user wants no fluff.", amongNewestFirst: live) == nil)
    }

    @Test("a live row with the new ask's own identity is never its victim")
    func sameIdentityIsNeverTheVictim() {
        let live = ["The user prefers short answers", "The user prefers long answers."]
        #expect(StyleAxis.newestRetired(by: "the user prefers short answers.", amongNewestFirst: live)
            == "The user prefers long answers.")
    }
}
