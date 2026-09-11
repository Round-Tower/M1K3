//
//  DistillationAttributionTests.swift
//  M1K3ChatTests
//
//  #284: the distiller attributed things M1K3 OFFERED — "if you're feeling
//  nostalgic…", "if you'd rather chat about…" — to the user, because nothing
//  checked WHO asserted a candidate fact. These pin the deterministic
//  backstop: a trivial user turn skips the slice entirely, and a fact must
//  share real content with something the user actually said.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-11, Confidence 0.85 (both rules are
//  pure and fully pinned here, including the documented "yes"-confirmation
//  false negative; the coordinator-level wiring is pinned separately in
//  MemoryDistillationCoordinatorTests).
//  Prior: Unknown
//

@testable import M1K3Chat
import Testing

struct DistillationAttributionTests {
    // MARK: - userContributionIsTrivial

    @Test("a one-word greeting is trivial — the July slice, #284's live witness")
    func greetingIsTrivial() {
        #expect(DistillationAttribution.userContributionIsTrivial(turns: [
            ChatTurn(role: .user, text: "yo"),
            ChatTurn(role: .assistant, text: "Ah, Kev. Monday, 6th July 2026 — the Mac's uptime's a bit over a year…"),
        ]))
    }

    @Test("a three-word self-statement is never trivial, however short — \"I'm a vet\"")
    func threeShortWordsAreNotTrivial() {
        // Word count is the only gate: nine characters, three words, one fact.
        #expect(!DistillationAttribution.userContributionIsTrivial(turns: [
            ChatTurn(role: .user, text: "I'm a vet"),
            ChatTurn(role: .assistant, text: "Noted."),
        ]))
    }

    @Test("several short acknowledgements stay trivial (every turn two words or fewer)")
    func shortAcknowledgementsAreTrivial() {
        #expect(DistillationAttribution.userContributionIsTrivial(turns: [
            ChatTurn(role: .user, text: "yo"),
            ChatTurn(role: .assistant, text: "Howdy!"),
            ChatTurn(role: .user, text: "sure"),
            ChatTurn(role: .assistant, text: "Grand."),
        ]))
    }

    @Test("two long words still count as trivial — the word-count floor, not just length")
    func twoLongWordsAreTrivial() {
        #expect(DistillationAttribution.userContributionIsTrivial(turns: [
            ChatTurn(role: .user, text: "Antidisestablishmentarianism absolutely"),
            ChatTurn(role: .assistant, text: "Noted."),
        ]))
    }

    @Test("a short real statement is NOT trivial — \"I live in Cork\" is a fact, not a greeting")
    func shortRealStatementIsNotTrivial() {
        // The floor guards against greetings ("yo", "sure"), never against a
        // short sentence that carries a fact. 14 characters, four words.
        #expect(!DistillationAttribution.userContributionIsTrivial(turns: [
            ChatTurn(role: .user, text: "I live in Cork"),
            ChatTurn(role: .assistant, text: "Lovely spot."),
        ]))
        #expect(!DistillationAttribution.userContributionIsTrivial(turns: [
            ChatTurn(role: .user, text: "My dog is Rex"),
            ChatTurn(role: .assistant, text: "Good name."),
        ]))
    }

    @Test("a real, multi-word contribution is not trivial")
    func realContributionIsNotTrivial() {
        #expect(!DistillationAttribution.userContributionIsTrivial(turns: [
            ChatTurn(role: .user, text: "My sister Aoife lives in Cork and prefers metric units."),
            ChatTurn(role: .assistant, text: "Noted!"),
        ]))
    }

    // MARK: - isAnchored

    @Test("a paraphrase sharing one real content token is anchored")
    func paraphraseSharingOneTokenIsAnchored() {
        #expect(DistillationAttribution.isAnchored(
            fact: "Kev teaches primary school in Ardmore.",
            userTurns: ["I teach primary school in Ardmore"]
        ))
    }

    @Test("short words and numbers anchor too — \"dog\", \"Rex\", \"42\" are content, not noise")
    func shortWordsAndNumbersAnchor() {
        // Three-letter words are most of what a short fact is made of; a
        // four-letter minimum dropped every one of these on the floor.
        #expect(DistillationAttribution.isAnchored(
            fact: "Kev's dog is called Rex.",
            userTurns: ["My dog is Rex"]
        ))
        #expect(DistillationAttribution.isAnchored(
            fact: "Kev is 42 years old.",
            userTurns: ["I'm 42"]
        ))
        #expect(DistillationAttribution.isAnchored(
            fact: "Kev lives in Cork.",
            userTurns: ["I live in Cork"]
        ))
    }

    @Test("common three-letter words never anchor on their own")
    func threeLetterFunctionWordsDoNotAnchor() {
        // "the", "and", "you", "was" appear in nearly every sentence — sharing
        // one proves nothing (the honey witness shares "the" with "yo, the usual").
        #expect(!DistillationAttribution.isAnchored(
            fact: #"Kev is nostalgic about the "honey in Egyptian tombs" story."#,
            userTurns: ["yo, the usual for me and you"]
        ))
    }

    @Test("an assistant-offered aside with no echo in the user's own words is unanchored")
    func assistantOfferedAsideIsUnanchored() {
        // The live #284 witness: the assistant volunteered the honey story,
        // "yo" never mentioned it.
        #expect(!DistillationAttribution.isAnchored(
            fact: #"Kev is nostalgic about the "honey in Egyptian tombs" story."#,
            userTurns: ["yo"]
        ))
        #expect(!DistillationAttribution.isAnchored(
            fact: "Kev is interested in AI ethics.",
            userTurns: ["yo"]
        ))
    }

    @Test("the user's own name never anchors a fact by itself — the same conflation MemoryFactValidator guards")
    func ownNameAloneDoesNotAnchor() {
        #expect(!DistillationAttribution.isAnchored(
            fact: "Kev is a great guy.",
            userTurns: ["Kev, Kev, Kev"]
        ))
    }

    /// KNOWN FALSE NEGATIVE, documented rather than fixed (#284's proposed
    /// shape names this explicitly): a bare "yes" confirming an assistant's
    /// question carries no content tokens of its own, so a fact built from
    /// the assistant's question is dropped even though the user genuinely
    /// confirmed it. Losing this recall is the accepted cost of a
    /// deterministic, fail-closed fence — worth a smarter anchor later
    /// (e.g. crediting a short affirmative against the PRIOR assistant
    /// turn's question), not today.
    @Test("a bare yes-confirmation is unanchored (known false negative)")
    func yesConfirmationIsUnanchoredKnownFalseNegative() {
        #expect(!DistillationAttribution.isAnchored(
            fact: "Kev still lives in Cork.",
            userTurns: ["yes"]
        ))
    }

    @Test("an empty or all-stopword fact is unanchored — fail closed, never a crash")
    func emptyOrStopwordOnlyFactIsUnanchored() {
        #expect(!DistillationAttribution.isAnchored(fact: "", userTurns: ["My sister lives in Cork"]))
        #expect(!DistillationAttribution.isAnchored(
            fact: "This is that with them.",
            userTurns: ["My sister lives in Cork"]
        ))
    }
}
