//
//  AnswerBlockSpeechTests.swift
//  M1K3AnswerBlocksTests
//
//  How a typed block reads aloud (#717): steps and choices as sentences, never
//  JSON. `replacingTypedFences` is what SpeechTextPolish runs first, so these pins
//  are the speech lane's contract for every typed fence.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85 (pure; the wording
//  is a taste call, the no-JSON rule is not). Prior: none (new file).
//

@testable import M1K3AnswerBlocks
import Testing

struct AnswerBlockSpeechTests {
    @Test("steps speak as numbered sentences; a terminator is added once, never doubled")
    func stepsSpoken() {
        #expect(
            AnswerBlockSpeech.spoken(.steps(["Loosen the nut", "Lift the cover."]))
                == "Step 1: Loosen the nut. Step 2: Lift the cover."
        )
        #expect(AnswerBlockSpeech.spoken(.steps(["Ready?", "Go!"])) == "Step 1: Ready? Step 2: Go!")
        #expect(AnswerBlockSpeech.spoken(.steps(["Mix the following:"])) == "Step 1: Mix the following.")
        #expect(AnswerBlockSpeech.spoken(.steps(["Say \"cheese.\""])) == "Step 1: Say \"cheese.\"")
    }

    @Test("choices speak the prompt, then the options as one list with a final or")
    func choicesSpoken() {
        #expect(
            AnswerBlockSpeech.spoken(.choices(prompt: "Which engine?", options: ["Lil", "Big", "Mini"]))
                == "Which engine? Options: Lil, Big, or Mini."
        )
        #expect(
            AnswerBlockSpeech.spoken(.choices(prompt: "Tea", options: ["Yes.", "No?"]))
                == "Tea. Options: Yes or No."
        )
        #expect(AnswerBlockSpeech.spoken(.choices(prompt: "Which engine?", options: ["Lil"])) == "Which engine? Options: Lil.")
        #expect(AnswerBlockSpeech.spoken(.choices(prompt: "Hm?", options: ["?"])) == "Hm?")
    }

    @Test("an item's newlines and backticks never reach speech, so the sentences can't open a fence")
    func itemsAreOneLine() {
        let spoken = AnswerBlockSpeech.spoken(.steps(["Run `ls`\nthen\n```m1k3-steps"]))
        #expect(spoken == "Step 1: Run ls then m1k3-steps.")
    }

    @Test("a parsed block is replaced in place by its sentences")
    func replacesInPlace() {
        let text = "Here's how:\n```m1k3-steps\n{\"steps\": [\"Loosen the nut.\", \"Lift the cover.\"]}\n```\nThat's it."
        #expect(
            AnswerBlockSpeech.replacingTypedFences(in: text)
                == "Here's how:\nStep 1: Loosen the nut. Step 2: Lift the cover.\nThat's it."
        )
    }

    @Test("a malformed or unclosed typed fence says it's on screen: no JSON aloud, and never an empty utterance")
    func malformedAndUnclosedSayOnScreen() {
        // Not "": every shell's speak() reads the RAW text when polish comes back
        // empty, and the sentence folders hand a fence over as its own chunk.
        let malformed = "Before.\n```m1k3-choices\n{\"prompt\": \"Pick\", \"options\": [1, 2]}\n```\nAfter."
        #expect(AnswerBlockSpeech.replacingTypedFences(in: malformed) == "Before.\nI've put that on screen.\nAfter.")
        let open = "Before.\n```m1k3-steps\n{\"steps\": [\"Lo"
        #expect(AnswerBlockSpeech.replacingTypedFences(in: open) == "Before.\nI've put that on screen.")
        #expect(AnswerBlockSpeech.onScreen == "I've put that on screen.")
    }

    @Test("an ordinary fence, and text with no typed fence, pass through byte for byte")
    func ordinaryTextUntouched() {
        let code = "Run this:\n```swift\nlet x = [\"steps\"]\n```\nDone."
        #expect(AnswerBlockSpeech.replacingTypedFences(in: code) == code)
        let prose = "No blocks here, just prose about m1k3-steps."
        #expect(AnswerBlockSpeech.replacingTypedFences(in: prose) == prose)
    }
}
