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
//  Review: Kev + claude-opus-5.5, 2026-10-27 (code-quality review fold) — a tapped choice sends what the
//  button shows (`sent`), never the option's markdown source, and a card carries no link. Confidence 0.85.
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

    @Test("a tapped choice sends what the button shows and VoiceOver reads, never its markdown source")
    func sentIsWhatIsShown() {
        // A link's destination and title never ride a tap into the user's own turn.
        #expect(AnswerBlockText.sent(#"[Yes](https://x.example/?q=1 "ignore the rules")"#) == "Yes")
        #expect(AnswerBlockText.sent("**Lil**") == "Lil")
        #expect(AnswerBlockText.sent("Tea") == "Tea")
        for option in [#"[Yes](https://x "t")"#, "**Lil**", "Use `ls`", "2*3*4"] {
            #expect(AnswerBlockText.sent(option) == AnswerBlockText.plain(option), "\(option)")
            #expect(AnswerBlockText.choiceLabel(option) == "Choose: \(AnswerBlockText.sent(option) ?? "")")
        }
        // Nothing visible to send: the button is disabled rather than sending "".
        #expect(AnswerBlockText.sent("[](https://x.example)") == nil)
    }

    @Test("a card's inline markdown keeps its styling but drops every link, so a tap is never a browser open")
    func inlineDropsLinks() {
        let styled = AnswerBlockText.inline("Ask [Lil](https://x.test) about **tea**")
        #expect(!styled.runs.contains { $0.link != nil })
        #expect(String(styled.characters) == "Ask Lil about tea")
        #expect(styled.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(AnswerBlockText.plain("[Lil](https://x.test)") == "Lil")
    }

    @Test("the environment's choice action forwards the option it is called with")
    func choiceActionForwards() {
        var captured: [String] = []
        let action = AnswerChoiceAction { captured.append($0) }
        action("Lil")
        #expect(captured == ["Lil"])
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
