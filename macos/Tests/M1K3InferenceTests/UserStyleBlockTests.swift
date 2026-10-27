//
//  UserStyleBlockTests.swift
//  M1K3InferenceTests
//
//  #699 Phase 1: the style line's text, rendered from the user's `.style` memories
//  newest first. Whole facts in order, inside the cap; an older ask never leapfrogs a
//  newer one that did not fit (the older is often what the newer corrected), and the
//  newest alone over the cap is cut at a word boundary rather than lost.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85, Prior: none (new file)
//

@testable import M1K3Inference
import Testing

struct UserStyleBlockTests {
    @Test("whole facts render newest first, one sentence after another")
    func rendersNewestFirst() {
        let rendered = UserStyleBlock.render(
            newestFirst: ["The user wants no bullet lists.", "The user prefers short answers."], cap: 160
        )
        #expect(rendered == "The user wants no bullet lists. The user prefers short answers.")
    }

    @Test("whitespace is trimmed and a fact without closing punctuation gets a full stop")
    func trimsAndPunctuates() {
        #expect(UserStyleBlock.render(newestFirst: ["  no lists  ", "short answers!"], cap: 160)
            == "no lists. short answers!")
    }

    @Test("nothing to render is nil")
    func emptyIsNil() {
        #expect(UserStyleBlock.render(newestFirst: [], cap: 160) == nil)
        #expect(UserStyleBlock.render(newestFirst: ["  ", "\n"], cap: 160) == nil)
    }

    @Test("the block ends at the first fact that would cross the cap: an older ask never leapfrogs a newer one")
    func stopsAtTheFirstOverflow() {
        let newest = "The user prefers answers of three sentences or fewer."
        let tooLong = String(repeating: "x", count: 120) + "."
        let rendered = UserStyleBlock.render(newestFirst: [newest, tooLong, "No lists."], cap: 160)
        #expect(rendered == newest)
    }

    @Test("the rendered block never exceeds the cap")
    func neverExceedsTheCap() {
        let facts = [
            "The user prefers short answers.",
            "The user wants no bullet lists.",
            "The user prefers metric units in answers.",
            "The user wants code before the explanation.",
            "The user prefers plain words over jargon.",
        ]
        for cap in [10, 31, 32, 63, 64, 100, 160] {
            let rendered = UserStyleBlock.render(newestFirst: facts, cap: cap) ?? ""
            #expect(rendered.count <= cap, "cap \(cap): \(rendered.count) chars")
        }
    }

    @Test("the newest fact alone over the cap is cut at a word boundary with an ellipsis, never dropped")
    func newestAloneOverTheCapIsCut() throws {
        let long = "The user prefers " + Array(repeating: "very", count: 40).joined(separator: " ") + " short answers."
        let rendered = try #require(UserStyleBlock.render(newestFirst: [long, "No lists."], cap: 60))
        #expect(rendered.count <= 60)
        #expect(rendered.hasPrefix("The user prefers very very"))
        #expect(rendered.hasSuffix("very…"))
        #expect(!rendered.contains("No lists."))
    }
}
