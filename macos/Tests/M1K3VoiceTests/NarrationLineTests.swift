//
//  NarrationLineTests.swift
//  M1K3VoiceTests
//
//  The notch HUD shows ONE line: the sentence being spoken. A visiting
//  agent's multi-paragraph `speak` used to render as stacked full-width
//  lines the panel clipped on both sides (Kev's screenshot, 2026-09-11).
//

@testable import M1K3Voice
import Testing

struct NarrationLineTests {
    @Test("before any word is reported, the first sentence")
    func firstSentenceByDefault() {
        #expect(NarrationLine.current(in: "One two. Three four.", wordRange: nil) == "One two.")
    }

    @Test("the sentence containing the word being spoken (UTF-16 offsets)")
    func sentenceContainingTheWord() {
        let text = "One two.\nThree four.\nFive six."
        let three = 9 ..< 14 // "Three"
        #expect(NarrationLine.current(in: text, wordRange: three) == "Three four.")
        let six = 26 ..< 29 // "six"
        #expect(NarrationLine.current(in: text, wordRange: six) == "Five six.")
    }

    @Test("runs of whitespace inside a sentence collapse to one space")
    func whitespaceCollapses() {
        #expect(NarrationLine.current(in: "a line\tbroken   here.", wordRange: nil) == "a line broken here.")
    }

    @Test("a newline is always a boundary — a hard-wrapped sentence shows as two lines in turn")
    func newlineSplitsEvenMidSentence() {
        // The HUD is one line at a time; a wrap inside a sentence becomes two
        // short lines as the word range crosses it, never a clipped tall block.
        #expect(NarrationLine.current(in: "a line\nbroken here.", wordRange: nil) == "a line")
        #expect(NarrationLine.current(in: "a line\nbroken here.", wordRange: 7 ..< 13) == "broken here.")
    }

    @Test("a paragraph without terminal punctuation ends at the newline")
    func newlineEndsASentence() {
        #expect(NarrationLine.current(in: "intro line\nSecond one.", wordRange: nil) == "intro line")
        #expect(NarrationLine.current(in: "intro line\nSecond one.", wordRange: 11 ..< 17) == "Second one.")
    }

    @Test("a word range past the end still resolves to the last sentence")
    func rangePastTheEnd() {
        #expect(NarrationLine.current(in: "One. Two.", wordRange: 40 ..< 44) == "Two.")
    }

    @Test("empty or whitespace-only text is an empty line")
    func emptyText() {
        #expect(NarrationLine.current(in: "", wordRange: nil) == "")
        #expect(NarrationLine.current(in: " \n ", wordRange: nil) == "")
    }

    @Test("an ellipsis, a question and an exclamation all end a sentence")
    func terminalPunctuation() {
        let text = "Wait… really? Yes! Done."
        #expect(NarrationLine.current(in: text, wordRange: 6 ..< 12) == "really?")
        #expect(NarrationLine.current(in: text, wordRange: 14 ..< 17) == "Yes!")
    }
}
