//
//  StreamFoldTests.swift
//  M1K3InferenceTests
//
//  Pins the snapshot-vs-delta normalisation rule all stream consumers share
//  (ChatSession.fold, StreamingReasoningSplitter, ConclusionStreamSplitter).
//
//  Signed: Kev + claude-fable-5, 2026-07-02, Confidence 0.9, Prior: Unknown
//  Review: Kev + claude-opus-5.5, 2026-11-19 (the 11-18 wide eval read: two checklists frozen at "## ⚙" / "### ⏱" after
//  441 / 410 decoded tokens) — `variationSelectorSnapshot` pins the scalar prefix.
//

@testable import M1K3Inference
import Testing

struct StreamFoldTests {
    @Test("a cumulative snapshot replaces the accumulated text")
    func snapshotReplaces() {
        #expect(StreamFold.fold(current: "Hello", chunk: "Hello wor") == "Hello wor")
        #expect(StreamFold.delta(current: "Hello", chunk: "Hello wor") == " wor")
    }

    @Test("a plain delta appends")
    func deltaAppends() {
        #expect(StreamFold.fold(current: "Hello", chunk: " world") == "Hello world")
        #expect(StreamFold.delta(current: "Hello", chunk: " world") == " world")
    }

    @Test("empty current treats the first chunk identically under both readings")
    func emptyCurrent() {
        // "" is a prefix of everything, so the snapshot branch fires — and
        // produces the same result the delta branch would. The rule needs no
        // special case for the first chunk.
        #expect(StreamFold.fold(current: "", chunk: "Hi") == "Hi")
        #expect(StreamFold.delta(current: "", chunk: "Hi") == "Hi")
    }

    @Test("an identical snapshot contributes nothing new")
    func identicalSnapshot() {
        #expect(StreamFold.fold(current: "same", chunk: "same") == "same")
        #expect(StreamFold.delta(current: "same", chunk: "same") == "")
    }

    /// `String.hasPrefix` compares grapheme clusters: "## ⚙" is not a prefix of "## ⚙\u{FE0F} During",
    /// because the variation selector joins the gear's cluster. A snapshot that completes an emoji must
    /// still read as a snapshot, or the fold appends it whole and the text doubles (2026-11-19 eval read).
    @Test("a snapshot that completes an emoji (U+FE0F) still replaces")
    func variationSelectorSnapshot() {
        #expect(StreamFold.fold(current: "## ⚙", chunk: "## ⚙\u{FE0F} During") == "## ⚙\u{FE0F} During")
        #expect(StreamFold.delta(current: "## ⚙", chunk: "## ⚙\u{FE0F} During") == "\u{FE0F} During")
        #expect(StreamFold.extends("## ⚙\u{FE0F}", "## ⚙"))
        #expect(!StreamFold.extends("## ⚘", "## ⚙"))
    }

    /// The same bug class for every cluster a later chunk completes: a skin tone, a ZWJ sequence.
    @Test("a skin tone or a ZWJ arriving in a later chunk folds without doubling")
    func laterClusterScalars() {
        #expect(StreamFold.fold(current: "Hi 👋", chunk: "Hi 👋\u{1F3FD} there") == "Hi 👋\u{1F3FD} there")
        #expect(StreamFold.delta(current: "👩", chunk: "👩\u{200D}💻") == "\u{200D}💻")
        #expect(StreamFold.fold(current: "👩", chunk: "\u{200D}💻") == "👩\u{200D}💻", "a delta re-joins the cluster on append")
    }
}
