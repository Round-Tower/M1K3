//
//  FollowUpSplitTests.swift
//  M1K3InferenceTests
//
//  M1K3 offers up to 3 tap-to-send follow-up questions after an answer, carried
//  as a trailing "FOLLOWUPS: [...]" sentinel line — never required, always
//  stripped from the visible answer regardless of whether it parses, so a
//  malformed trailer degrades to "no chips" rather than leaking a raw JSON
//  fragment into the chat bubble.
//
//  Signed: Kev + claude-sonnet-5, 2026-07-14, Confidence 0.85, Prior: Unknown

import Foundation
@testable import M1K3Inference
import Testing

struct FollowUpSplitTests {
    @Test("plain text with no trailer has no follow-ups")
    func noTrailer() {
        let result = FollowUpSplit.split("The weather is sunny.")
        #expect(result.answer == "The weather is sunny.")
        #expect(result.followUps == [])
    }

    @Test("a well-formed trailer is parsed and stripped from the answer")
    func wellFormed() {
        let result = FollowUpSplit.split(
            "It's sunny in Boston.\nFOLLOWUPS: [\"What about tomorrow?\", \"And New York?\", \"Chance of rain?\"]"
        )
        #expect(result.answer == "It's sunny in Boston.")
        #expect(result.followUps == ["What about tomorrow?", "And New York?", "Chance of rain?"])
    }

    @Test("more than 3 items is capped at 3")
    func capsAtThree() {
        let result = FollowUpSplit.split(
            "Answer.\nFOLLOWUPS: [\"one?\", \"two?\", \"three?\", \"four?\", \"five?\"]"
        )
        #expect(result.followUps == ["one?", "two?", "three?"])
    }

    @Test("malformed JSON strips the trailer but yields no follow-ups")
    func malformedJSON() {
        let result = FollowUpSplit.split(
            "Answer.\nFOLLOWUPS: [\"unclosed string, oops"
        )
        #expect(result.answer == "Answer.")
        #expect(result.followUps == [])
    }

    @Test("an empty array strips the trailer with no follow-ups")
    func emptyArray() {
        let result = FollowUpSplit.split("Answer.\nFOLLOWUPS: []")
        #expect(result.answer == "Answer.")
        #expect(result.followUps == [])
    }

    @Test("non-string array elements degrade the whole trailer to no follow-ups")
    func nonStringElements() {
        let result = FollowUpSplit.split("Answer.\nFOLLOWUPS: [\"real question?\", 42, null]")
        #expect(result.answer == "Answer.")
        #expect(result.followUps == [])
    }

    @Test("blank or whitespace-only questions are dropped, not counted")
    func blankQuestionsDropped() {
        let result = FollowUpSplit.split(
            "Answer.\nFOLLOWUPS: [\"Real one?\", \"   \", \"\"]"
        )
        #expect(result.followUps == ["Real one?"])
    }

    @Test("an overlong question is dropped as the model rambling, not truncated")
    func overlongQuestionDropped() {
        let long = String(repeating: "a", count: 200) + "?"
        let result = FollowUpSplit.split("Answer.\nFOLLOWUPS: [\"Short one?\", \"\(long)\"]")
        #expect(result.followUps == ["Short one?"])
    }

    @Test("whitespace around the answer and trailer is trimmed")
    func whitespaceTrimmed() {
        let result = FollowUpSplit.split("  Answer.  \n\n  FOLLOWUPS: [\"Q?\"]  ")
        #expect(result.answer == "Answer.")
        #expect(result.followUps == ["Q?"])
    }

    @Test("case and spacing around the sentinel are tolerated")
    func sentinelSpacingTolerated() {
        let result = FollowUpSplit.split("Answer.\nFOLLOWUPS:[\"Q?\"]")
        #expect(result.answer == "Answer.")
        #expect(result.followUps == ["Q?"])
    }

    @Test("duplicate questions collapse to one")
    func duplicatesCollapse() {
        let result = FollowUpSplit.split(
            "Answer.\nFOLLOWUPS: [\"Same?\", \"same?\", \"Different?\"]"
        )
        #expect(result.followUps == ["Same?", "Different?"])
    }
}

// Review: Kev + claude-fable-5.1, 2026-09-12 — the trailer's SHAPE is tolerated, not just
// its spelling: Golden Gate Mini wrote "Follow-ups:" / "**FOLLOW-UPS:**" lines that the
// exact sentinel missed, so they stayed in the bubble, were read aloud, and were replayed
// into the next turn's history (launch snag list). Line-start, plural, colon — never a
// mid-sentence "follow up".
extension FollowUpSplitTests {
    @Test("a hyphenated / spaced / markdown-bold variant at a line start is a trailer")
    func variantsAreTrailers() {
        for trailer in ["Follow-ups:", "FOLLOW-UPS:", "Follow ups:", "**Follow-ups:**", "## Follow-ups:"] {
            let result = FollowUpSplit.split("Answer.\n\(trailer) [\"Q?\"]")
            #expect(result.answer == "Answer.", Comment(rawValue: trailer))
            #expect(result.followUps == ["Q?"], Comment(rawValue: trailer))
        }
    }

    @Test("a prose trailer under a variant is stripped even though it parses to no chips")
    func proseTrailerStripped() {
        let result = FollowUpSplit.split("Answer.\nFollow-ups:\n- What next?\n- And then?")
        #expect(result.answer == "Answer.")
        #expect(result.followUps.isEmpty)
    }

    @Test("a mid-sentence 'follow up' is prose, not a trailer")
    func midSentenceIsProse() {
        let text = "I'll follow up: the dentist on Monday, then the follow-ups list."
        #expect(FollowUpSplit.split(text).answer == text)
        #expect(FollowUpSplit.trailerStart(in: text) == nil)
    }

    @Test("trailerStart finds the exact sentinel mid-line and the variants at a line start")
    func trailerStartLocations() {
        let exact = "Answer. FOLLOWUPS: []"
        #expect(FollowUpSplit.trailerStart(in: exact) == exact.range(of: "FOLLOWUPS:")?.lowerBound)
        let variant = "Answer.\n  Follow-ups: []"
        #expect(FollowUpSplit.trailerStart(in: variant) == variant.range(of: "  Follow-ups:")?.lowerBound)
    }
}
