//
//  ReasoningTailTests.swift
//  M1K3ChatTests
//
//  The live reasoning panel shows only the thought's tail while it streams, so its
//  per-flush render cost stays flat however long the thought runs.
//

@testable import M1K3Chat
import Testing

struct ReasoningTailTests {
    @Test("a thought within the limit shows whole")
    func shortThoughtWhole() {
        let thought = "The Mixed label is wrong, so that box holds one fruit."
        #expect(ReasoningTail.live(thought, limit: 100) == thought)
    }

    @Test("a long thought keeps only its tail, marked as cut")
    func longThoughtTail() {
        let thought = String(repeating: "a word ", count: 400) + "the last line"
        let tail = ReasoningTail.live(thought, limit: 200)
        #expect(tail.hasPrefix("… "))
        #expect(tail.hasSuffix("the last line"))
        #expect(tail.count <= 202)
    }

    @Test("the cut lands on a word boundary, never mid-word")
    func cutsAtWord() {
        let thought = String(repeating: "abcdefghij ", count: 50)
        let tail = ReasoningTail.live(thought, limit: 105)
        #expect(tail.dropFirst(2).hasPrefix("abcdefghij"))
    }

    @Test("the cut prefers a line break when one sits early in the window")
    func prefersLineBreak() {
        let thought = String(repeating: "x ", count: 200) + "older thought\nNow check the Apples box. " +
            String(repeating: "y ", count: 20)
        let tail = ReasoningTail.live(thought, limit: 80)
        #expect(tail.dropFirst(2).hasPrefix("Now check the Apples box."))
    }

    @Test("one unbroken run longer than the limit still caps")
    func unbrokenRunCaps() {
        let thought = String(repeating: "z", count: 500)
        let tail = ReasoningTail.live(thought, limit: 100)
        #expect(tail == "… " + String(repeating: "z", count: 100))
    }

    @Test("a zero or negative limit shows only the cut mark, never traps")
    func nonPositiveLimitClamps() {
        #expect(ReasoningTail.live("some thought", limit: 0) == "… ")
        #expect(ReasoningTail.live("some thought", limit: -5) == "… ")
    }
}
