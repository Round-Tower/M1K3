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
//  Review: Kev + claude-opus-5.5, 2026-10-27 (pre-push review fold) — every cue and every lead is now pinned one
//  by one, with the list sizes snapshotted, so an edit to either is a visible diff; the task-verb exclusion, the
//  word boundaries and the filler path are pinned on their own. New fail-closed cases: the verb the prompt
//  mandates ("prefers"/"wants") never anchors, and the anchor and the ask must sit in ONE sentence or line, so a
//  pasted paragraph cannot vouch for a style fact. Confidence 0.85.
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
            "ok, avoid bullet points", // a lead after a filler (no cue in the turn: only the lead path passes it)
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

    // MARK: - The mandated verb is not evidence

    @Test("\"prefers\" and \"wants\" are the prompt's own scaffold, so a turn sharing only them never anchors")
    func templateVerbsDoNotAnchor() {
        #expect(!asks("The user wants no bullet lists.", ["please tell me what my sister wants for her birthday"]))
        #expect(!asks("The user prefers short answers.", ["my sister prefers tea, could you suggest a blend please"]))
        // A real content token still anchors beside them.
        #expect(asks("The user prefers short answers.", ["I prefer short answers please"]))
    }

    @Test("a fact made only of the scaffold has nothing to anchor on")
    func scaffoldOnlyFactFails() {
        #expect(!asks("The user prefers.", ["please, the user prefers"]))
    }

    // MARK: - One sentence carries both

    @Test("the anchor and the ask must sit in one sentence or line: a pasted paragraph cannot vouch for a style fact")
    func anchorAndAskShareOneSegment() {
        let pasted = """
        Dear team, please find the minutes attached.
        The answers to the survey were short this quarter.
        """
        #expect(!asks("The user prefers short answers.", [pasted]))
        #expect(!asks("The user prefers short answers.", ["Please read this. Your answers on the quiz were short."]))
        #expect(!asks("The user prefers short answers.", ["Stop! The answers were short; it was fine"]))
    }

    @Test("a polite closer in the same sentence still asks, and an opener before it doesn't break it")
    func oneSentenceAsksPass() {
        #expect(asks("The user prefers shorter answers.", ["Thanks! Shorter answers please."]))
        #expect(asks("The user prefers shorter answers.", ["Great work.\nCan you keep the answers shorter?"]))
        #expect(asks("The user wants no bullet points.", ["Thanks! Skip the bullet points."]))
    }

    @Test("a turn splits at line breaks and at sentence ends, never inside a number")
    func segmentsSplitAtSentencesAndLines() {
        #expect(StyleAskFence.segments("Thanks! Shorter answers please.") == ["Thanks!", "Shorter answers please."])
        #expect(StyleAskFence.segments("one\ntwo") == ["one", "two"])
        #expect(StyleAskFence.segments("keep it to 3.5 lines?") == ["keep it to 3.5 lines?"])
        #expect(StyleAskFence.segments("  \n ").isEmpty)
    }

    // MARK: - The lists, one entry at a time

    @Test("every request cue reads as a request on its own, word-bounded after normalisation")
    func everyCueMatches() {
        for cue in StyleAskFence.requestCues {
            #expect(StyleAskFence.isRequest("\(cue) bullet points"), "\(cue)")
            #expect(StyleAskFence.isRequest("well \(cue) bullet points"), "\(cue) mid-turn")
        }
    }

    @Test("every imperative lead reads as a request when it opens a turn")
    func everyLeadMatches() {
        for lead in StyleAskFence.imperativeLeads {
            #expect(StyleAskFence.isRequest("\(lead) bullet points"), "\(lead)")
        }
    }

    @Test("the lists are snapshotted, so an edit to either is a visible, reviewed diff")
    func listsAreSnapshotted() {
        #expect(StyleAskFence.requestCues.count == 54)
        #expect(Set(StyleAskFence.requestCues).count == StyleAskFence.requestCues.count) // no duplicates
        #expect(StyleAskFence.imperativeLeads == [
            "be", "keep", "skip", "stop", "use", "avoid", "drop", "ditch", "lose", "cut",
            "answer", "reply", "respond", "talk", "speak", "always", "never", "no", "less", "fewer",
        ])
    }

    @Test("task verbs open asks for content, never a standing ask about answers")
    func taskVerbsAreNotLeads() {
        for verb in ["write", "explain", "tell", "give", "make"] {
            #expect(!StyleAskFence.imperativeLeads.contains(verb), "\(verb)")
        }
        #expect(!StyleAskFence.isRequest("write me a short poem"))
        #expect(!StyleAskFence.isRequest("explain how bridges work"))
        #expect(!StyleAskFence.isRequest("tell me about Cork"))
        #expect(!StyleAskFence.isRequest("give me a recipe"))
        #expect(!StyleAskFence.isRequest("make a list of tasks"))
        #expect(!asks("The user prefers short answers.", ["write me a short summary of the answers"]))
    }

    @Test("cues are word-bounded: pleased, stopped and regardless are not please, stop and less")
    func cuesAreWordBounded() {
        #expect(!StyleAskFence.isRequest("I was pleased with the answers"))
        #expect(!StyleAskFence.isRequest("they stopped by with answers"))
        #expect(!StyleAskFence.isRequest("regardless of the lists"))
        #expect(!StyleAskFence.isRequest("the shortest answers won"))
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
