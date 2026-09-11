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

    @Test("several one-word acknowledgements stay trivial")
    func shortAcknowledgementsAreTrivial() {
        #expect(DistillationAttribution.userContributionIsTrivial(turns: [
            ChatTurn(role: .user, text: "yo"),
            ChatTurn(role: .assistant, text: "Howdy!"),
            ChatTurn(role: .user, text: "sure"),
            ChatTurn(role: .assistant, text: "Grand."),
        ]))
    }

    @Test("two words can be a fact — \"I'm diabetic\" is never trivial (review 2 on #288)")
    func twoWordDisclosureIsNotTrivial() {
        // The gate exists to skip a distiller call on a bare greeting, nothing
        // more: the anchor fence below is what keeps offered facts out. So
        // only a slice of single-word turns is trivial.
        for text in ["I'm diabetic", "I'm vegetarian", "Antidisestablishmentarianism absolutely"] {
            #expect(!DistillationAttribution.userContributionIsTrivial(turns: [
                ChatTurn(role: .user, text: text),
                ChatTurn(role: .assistant, text: "Noted."),
            ]), "\(text)")
        }
    }

    @Test("a single digit never anchors — \"step 1\" is not \"1 sibling\"")
    func singleDigitDoesNotAnchor() {
        #expect(!DistillationAttribution.isAnchored(
            fact: "Kev has 1 sibling.",
            userTurns: ["step 1 is done"]
        ))
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
        // Review 6 on #288: the names come from the ACCOUNT, not a constant —
        // and "Kev" counts for "Kevin" because that is how people are addressed.
        let names = DistillationAttribution.userNames(fullName: "Kevin Murphy", shortName: "kevinmurphy")
        #expect(names.exact == ["kevin", "murphy", "kevinmurphy"])
        #expect(names.given == "kevin")
        #expect(!DistillationAttribution.isAnchored(
            fact: "Kev is a great guy.",
            userTurns: ["Kev, Kev, Kev"],
            selfNames: names
        ))
        #expect(!DistillationAttribution.isAnchored(
            fact: "Kevin Murphy is a great guy.",
            userTurns: ["Kevin Murphy here."],
            selfNames: names
        ))
        // The same shape for another account: her name is filtered, not Kev's.
        let alice = DistillationAttribution.userNames(fullName: "Alice Ní Bhriain", shortName: "alice")
        #expect(!DistillationAttribution.isAnchored(
            fact: "Alice is a great guy.",
            userTurns: ["Alice, Alice, Alice"],
            selfNames: alice
        ))
        // With no names supplied, nothing is filtered — the guard is opt-in evidence, never a default.
        #expect(DistillationAttribution.isAnchored(fact: "Alice is a great guy.", userTurns: ["Alice, Alice, Alice"]))
        // Two-letter pieces never count as the name ("Ní" → dropped).
        #expect(!alice.exact.contains("ní"))
    }

    @Test("only the given name matches by fragment — a surname's leading letters are a word, not a name")
    func fragmentRuleIsGivenNameOnly() {
        // Review 7 on #288: any-prefix-of-any-name swallowed "fit" (Fitzgerald)
        // and "gran" (Grant) — ordinary words that would have blocked real anchors.
        let fitz = DistillationAttribution.userNames(fullName: "Alexandra Fitzgerald", shortName: "afitz")
        #expect(!DistillationAttribution.isSelfName("fit", names: fitz))
        #expect(DistillationAttribution.isSelfName("fitzgerald", names: fitz))
        #expect(DistillationAttribution.isSelfName("alex", names: fitz))
        let grant = DistillationAttribution.userNames(fullName: "Kevin Grant", shortName: "kgrant")
        #expect(!DistillationAttribution.isSelfName("gran", names: grant))
        #expect(DistillationAttribution.isSelfName("kev", names: grant))
        #expect(!DistillationAttribution.isSelfName("kg", names: grant)) // under three letters is never a name
        // A cat that is very fit still anchors for Alexandra Fitzgerald.
        #expect(DistillationAttribution.isAnchored(
            fact: "Alexandra's cat is very fit.",
            userTurns: ["my cat is very fit these days"],
            selfNames: fitz
        ))
        // KNOWN, ACCEPTED COST: an ordinary word that is a fragment of the
        // GIVEN name is treated as the name — "ale" for Alexandra. Fail-closed,
        // like the "yes" case below; named here so the trade-off stays deliberate.
        #expect(DistillationAttribution.isSelfName("ale", names: fitz))
    }

    @Test("a short given name keeps the given slot — the surname never inherits the fragment leniency")
    func shortGivenNameDoesNotPromoteTheSurname() {
        // Review 8 on #288: `given` was the first token to SURVIVE the ≥3
        // filter, so "Ed Grant" made "grant" the given name and "gran" a
        // self-name again. Raw first token now, whatever its length.
        let ed = DistillationAttribution.userNames(fullName: "Ed Grant", shortName: "edgrant")
        #expect(ed.given == "ed")
        #expect(ed.exact == ["grant", "edgrant"])
        #expect(!DistillationAttribution.isSelfName("gran", names: ed))
        #expect(DistillationAttribution.isSelfName("grant", names: ed))
        #expect(DistillationAttribution.isAnchored(
            fact: "Ed's gran visits every Sunday.",
            userTurns: ["my gran visits every Sunday"],
            selfNames: ed
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
