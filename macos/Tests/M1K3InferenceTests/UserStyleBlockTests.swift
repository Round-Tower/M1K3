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
//  Review: Kev + claude-opus-5.5, 2026-10-27 (pre-push review fold) — the cap is pinned by exact outputs at
//  its boundaries (31, 62, 63 and 30 over two 31-char facts), so `<` for `<=` or a lost separator fails;
//  a cap of 0 or less is nil; a cut that lands on a word end keeps that word. Confidence 0.9.
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

    /// Two facts of exactly 31 characters each: joined, 63.
    private static let short = "The user prefers short answers."
    private static let lists = "The user wants no bullet lists."

    @Test("the cap's boundaries are exact: a fact that fits whole renders whole, one that doesn't waits")
    func capBoundariesAreExact() {
        #expect(Self.short.count == 31 && Self.lists.count == 31)
        let facts = [Self.short, Self.lists]
        #expect(UserStyleBlock.render(newestFirst: facts, cap: 31) == Self.short) // fits exactly, never cut
        #expect(UserStyleBlock.render(newestFirst: facts, cap: 62) == Self.short) // the separator makes 63
        #expect(UserStyleBlock.render(newestFirst: facts, cap: 63) == Self.short + " " + Self.lists)
        #expect(UserStyleBlock.render(newestFirst: facts, cap: 30) == "The user prefers short…")
    }

    @Test("a cap of zero or less renders nothing")
    func nonPositiveCapIsNil() {
        #expect(UserStyleBlock.render(newestFirst: [Self.short], cap: 0) == nil)
        #expect(UserStyleBlock.render(newestFirst: [Self.short], cap: -1) == nil)
    }

    @Test("a cut that lands exactly on a word end keeps that word")
    func cutOnAWordEndKeepsTheWord() {
        #expect(UserStyleBlock.cutAtAWord("aaa bbb ccc ddd", cap: 8) == "aaa bbb…")
        #expect(UserStyleBlock.cutAtAWord("aaa bbb ccc ddd", cap: 9) == "aaa bbb…")
        #expect(UserStyleBlock.cutAtAWord("aaa bbb ccc ddd", cap: 7) == "aaa…")
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
