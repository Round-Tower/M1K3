//
//  AnswerBlockTextTests.swift
//  M1K3AnswerBlocksTests
//
//  What the cards show and what VoiceOver reads (#717: "VoiceOver labels for every
//  block type"). The views are verify-by-launch; the words they hand VoiceOver are
//  pinned here.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85 (pure; wording is a
//  taste call). Prior: none (new file).
//

import Foundation
@testable import M1K3AnswerBlocks
import Testing

struct AnswerBlockTextTests {
    @Test("an item's inline markdown renders, and its plain form drops the markers")
    func inlineMarkdown() {
        let item = "Loosen the **nut** with `wrench`"
        #expect(AnswerBlockText.plain(item) == "Loosen the nut with wrench")
        let styled = AnswerBlockText.inline(item)
        #expect(String(styled.characters) == "Loosen the nut with wrench")
        #expect(styled.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }

    @Test("text that isn't valid markdown shows as written")
    func plainFallback() {
        #expect(AnswerBlockText.plain("2 * 3 = 6") == "2 * 3 = 6")
        #expect(AnswerBlockText.plain("") == "")
    }

    @Test("a step row reads its position, its count and its plain text")
    func stepLabel() {
        #expect(AnswerBlockText.stepLabel(number: 2, of: 5, step: "Lift the **cover**.") == "Step 2 of 5: Lift the cover.")
        #expect(AnswerBlockText.stepValue(done: true) == "Done")
        #expect(AnswerBlockText.stepValue(done: false) == "Not done")
    }

    @Test("a choice button reads as a choice, and says what a tap does")
    func choiceLabel() {
        #expect(AnswerBlockText.choiceLabel("Lil") == "Choose: Lil")
        #expect(AnswerBlockText.choiceHint == "Sends it as your next message")
    }

    @Test("every kind's skeleton has a label, so a block still streaming is announced")
    func skeletonLabels() {
        #expect(AnswerBlockText.skeletonLabel(.steps) == "Writing steps")
        #expect(AnswerBlockText.skeletonLabel(.choices) == "Writing choices")
        for kind in AnswerBlockKind.allCases {
            #expect(!AnswerBlockText.skeletonLabel(kind).isEmpty)
        }
    }
}
