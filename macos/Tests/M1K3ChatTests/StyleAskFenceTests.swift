//
//  StyleAskFenceTests.swift
//  M1K3ChatTests
//
//  #699: a `style` fact ("The user prefers short answers.") rides every system prompt
//  once stored, so it must come from something the user ASKED, never from how they
//  behave. The fence is the deterministic backstop on top of #284's anchor rule: one
//  user turn must both anchor the fact (share a content token, DistillationAttribution's
//  rule) and read as a request. These pin both halves, the issue's own two examples,
//  and the fail-closed cases: behaviour, a bare "yes" to M1K3's offer, and a cue in a
//  turn that anchors nothing. The cue list is a heuristic; each family is pinned so a
//  change to it is a visible, reviewed change.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.8 (the rule is pure and pinned;
//  whether the cue list is the right width is Kev's call, see the PR), Prior: none (new file)
//

@testable import M1K3Chat
import Testing

struct StyleAskFenceTests {
    private func asks(_ fact: String, _ turns: [String]) -> Bool {
        StyleAskFence.isExplicitAsk(fact: fact, userTurns: turns)
    }

    // MARK: - Explicit asks pass

    @Test("the issue's own examples are asks: \"shorter answers\" and \"no lists\"")
    func theIssuesExamplesPass() {
        #expect(asks("The user prefers shorter answers.", ["shorter answers"]))
        #expect(asks("The user wants no lists in answers.", ["no lists"]))
    }

    @Test("a polite request anchors and asks")
    func politeRequestPasses() {
        #expect(asks("The user prefers shorter answers.", ["can you keep answers shorter please"]))
        #expect(asks("The user wants answers kept brief.", ["Could you keep it brief from now on?"]))
    }

    @Test("every cue family reads as a request")
    func everyCueFamilyPasses() {
        let fact = "The user prefers answers without bullet points."
        for turn in [
            "please drop the bullet points", // politeness
            "don't use bullet points", // a negative
            "don’t use bullet points", // the curly apostrophe a keyboard sends
            "I'd rather you skipped bullet points", // a stated preference
            "from now on, no bullet points", // a standing directive
            "too many bullet points", // a complaint about the form
            "avoid bullet points", // an imperative lead
            "ok, skip the bullet points", // a lead after a filler
        ] {
            #expect(asks(fact, [turn]), "\(turn)")
        }
    }

    @Test("an anchoring ask in any turn of the slice is enough")
    func anyTurnMayCarryTheAsk() {
        #expect(asks("The user prefers shorter answers.", ["what's the weather in Cork", "shorter answers please"]))
    }

    // MARK: - Fail closed

    @Test("behaviour is not an ask: terse turns never anchor a style fact")
    func terseBehaviourFails() {
        #expect(!asks("The user prefers short answers.", ["ok", "what about cork", "thanks"]))
    }

    @Test("a description of how the user reads is not an ask, even when it anchors")
    func describedBehaviourFails() {
        #expect(!asks("The user prefers long answers.", ["I read every word of your long answers about history"]))
        #expect(!asks("The user prefers short answers.", ["your answers are short"]))
    }

    @Test("a bare \"yes\" to M1K3's own offer fails, #284's accepted false negative")
    func bareYesToAnOfferFails() {
        // The assistant's "Want me to keep things shorter?" is never a user turn.
        #expect(!asks("The user prefers shorter answers.", ["yes"]))
        #expect(!asks("The user prefers shorter answers.", ["yes please"]))
    }

    @Test("a cue in a turn that anchors nothing does not rescue a fact another turn anchors")
    func cueMustSitInTheAnchoringTurn() {
        #expect(!asks(
            "The user prefers short answers.",
            ["please tell me about Cork", "my answers on the quiz were short"]
        ))
    }

    @Test("\"no,\" as an interjection is not an imperative lead")
    func noCommaIsNotALead() {
        #expect(!StyleAskFence.isRequest("no, the lists were fine"))
        #expect(StyleAskFence.isRequest("no lists"))
    }

    @Test("a fact with no content tokens never passes")
    func emptyFactFails() {
        #expect(!asks("The user.", ["please, the user"]))
        #expect(!asks("The user prefers shorter answers.", []))
    }

    @Test("the user's own name is not evidence, as in the anchor rule")
    func selfNameIsNotEvidence() {
        let names = DistillationAttribution.UserNames(exact: ["kevin", "murphy"], given: "kevin")
        #expect(!StyleAskFence.isExplicitAsk(
            fact: "Kevin prefers terse replies.", userTurns: ["please, it's Kevin here"], selfNames: names
        ))
    }
}
