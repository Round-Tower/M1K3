//
//  ModelThinkingQuarantineTests.swift
//  M1K3KnowledgeTests
//
//  Pins the rule that decides whether a stored chunk is the MODEL'S OWN
//  THINKING rather than knowledge.
//
//  The live row that motivated it (Kev's store, found over MCP 2026-08-12) —
//  the Summary of "Call 2 Jul 2026 at 22:14", six weeks retrievable:
//
//      <|channel>thought Thinking Process: **Analyze the Request:** The user
//      wants me to analyze a short transcript snippet and present the analysis
//      using three specific headers...
//
//  Precision is the design, exactly as in SelfWiringQuarantine: this repo's own
//  source and design notes DISCUSS these tokens constantly, and quarantining a
//  document because it mentions `<think>` would be a worse bug than the one
//  being fixed. So the rule is POSITIONAL — the text must OPEN with a reasoning
//  marker — not a search for the marker anywhere.
//
//  Signed: Kev + claude-opus-5, 2026-08-12, Confidence 0.9 (authored red-first
//  against the real stored text, and the false positive that would hurt is
//  pinned alongside the true positive). Prior: Unknown
//

import Foundation
import M1K3Inference
@testable import M1K3Knowledge
import Testing

struct ModelThinkingQuarantineTests {
    /// The exact shape found in the live store.
    private let stored = """
    <|channel>thought Thinking Process: **Analyze the Request:** The user wants \
    me to analyze a short transcript snippet and present the analysis using \
    three specific headers: `Overview: <one paragraph>`, `Key points:`, and \
    `Action items:`.
    """

    @Test("the stored call summary that started this is caught")
    func theLiveRow() {
        #expect(ModelThinkingQuarantine.isModelThinking(stored))
    }

    @Test("both dialects open a block — qwen's and gemma-4's")
    func bothDialects() {
        #expect(ModelThinkingQuarantine.isModelThinking("<think>let me work through this"))
        #expect(ModelThinkingQuarantine.isModelThinking("<|channel>thought right, so"))
        // Leading whitespace/newlines are how stored text usually arrives.
        #expect(ModelThinkingQuarantine.isModelThinking("\n\n  <think>hmm"))
    }

    /// ★ The false positive that would actually hurt. This repo's own docs, this
    /// very file, and any design note about prompt hardening all contain these
    /// tokens — as SUBJECT MATTER. If Kev ever ingests M1K3's own documentation
    /// (he has ingested the OSS runsheet already), a presence-anywhere rule would
    /// hide it from him.
    @Test("a document that merely discusses the markers is left alone")
    func discussionIsNotThinking() {
        #expect(!ModelThinkingQuarantine.isModelThinking(
            "The summariser must strip <think> blocks before persisting a summary."
        ))
        #expect(!ModelThinkingQuarantine.isModelThinking(
            "gemma-4 emits <|channel>thought … <channel|> rather than the qwen pair."
        ))
        // Even repeatedly, and even in a heading — position is the whole rule.
        #expect(!ModelThinkingQuarantine.isModelThinking("""
        # Think tokens
        We saw <think> and </think> and <|channel>thought in the same response.
        """))
    }

    @Test("ordinary knowledge is untouched")
    func ordinaryText() {
        #expect(!ModelThinkingQuarantine.isModelThinking(
            "THE HIGH PRIESTESS sits on a rock. She's working on a pomegranate."
        ))
        #expect(!ModelThinkingQuarantine.isModelThinking(""))
        #expect(!ModelThinkingQuarantine.isModelThinking("   \n  "))
    }

    /// The scaffold WITHOUT a marker — "Thinking Process:" as an opener — is
    /// deliberately NOT matched. It is a plausible heading in a real document
    /// about decision-making, and the marker-led rule already catches the shape
    /// we have actually seen. Named so the omission reads as a decision.
    @Test("prose that opens like a scratchpad but carries no marker is left alone")
    func scaffoldWithoutMarkerIsNotEnough() {
        #expect(!ModelThinkingQuarantine.isModelThinking(
            "Thinking Process: first analyse the request, then draft the headers."
        ))
    }
}

/// The sweep itself, against a real store — the half the predicate tests cannot
/// see. Mirrors `SelfWiringQuarantineTests`' store-level pair, because the logic
/// unique to the extension (scan chunks INDIVIDUALLY, not joined; which kinds;
/// idempotency) is exactly what a predicate test leaves unpinned.
struct ModelThinkingSweepTests {
    private func makeStore() async throws -> (KnowledgeStore, DocumentIngester) {
        let store = try KnowledgeStore()
        return (store, DocumentIngester(store: store, embedder: HashingEmbeddingService()))
    }

    /// The real shape, taken from the live store: the poisoned SUMMARY is its own
    /// chunk and begins with the marker. That is why the sweep fired on Kev's Mac
    /// (`model-thinking quarantine: 1 item(s) re-kinded`, first launch) and why it
    /// scans chunks INDIVIDUALLY — joining an item's chunks would bury the marker
    /// mid-string and the positional rule would decline to fire.
    @Test("a poisoned summary moves; a clean call and an ordinary document stay")
    func sweepMovesOnlyThePoisoned() async throws {
        let (store, ingester) = try await makeStore()
        let poisoned = try await ingester.ingest(
            title: "Call 2 Jul 2026 at 22:14",
            text: """
            <|channel>thought Thinking Process: **Analyze the Request:** the user \
            wants me to present the analysis using three specific headers.
            """,
            kind: .call
        )
        let cleanCall = try await ingester.ingest(
            title: "Call 14 Jul 2026 at 17:34",
            text: "The caller opens with a casual greeting and asks how things are.",
            kind: .call
        )
        let doc = try await ingester.ingest(
            title: "Script_TheHighPriestess",
            text: "THE HIGH PRIESTESS sits on a rock. She's working on a pomegranate."
        )

        let swept = try store.quarantineModelThinking()

        #expect(swept == [poisoned.itemID])
        #expect(try store.allItems(kind: .quarantined).map(\.id) == [poisoned.itemID])
        #expect(try store.allItems(kind: .call).map(\.id) == [cleanCall.itemID])
        #expect(try store.allItems(kind: .document).map(\.id) == [doc.itemID])
    }

    /// ⚠️ THE BOUNDARY, pinned deliberately rather than discovered later. If a
    /// heading lands in the SAME chunk ahead of the marker, the positional rule
    /// does not fire — the text no longer OPENS with model thinking.
    ///
    /// Found by this very test file: my first fixture put `## Summary` above the
    /// marker and the sweep returned nothing, which briefly looked like a broken
    /// sweep and was actually an unrealistic fixture (the live row's summary is
    /// its own chunk). Recorded as a test because it is the tripwire: if chunking
    /// ever changes so headings ride with content, THIS is what starts passing
    /// while the sweep silently stops working. Widening the rule is the wrong
    /// answer — precision is the whole design — so the right response is to make
    /// the summary its own chunk, or to match per LINE with the same strictness.
    @Test("a marker behind a heading in the same chunk is NOT caught — known, and why")
    func markerBehindAHeadingIsOutOfScope() async throws {
        let (store, ingester) = try await makeStore()
        _ = try await ingester.ingest(
            title: "Call with a heading",
            text: """
            ## Summary
            <|channel>thought Thinking Process: the user wants three headers.
            """,
            kind: .call
        )
        #expect(try store.quarantineModelThinking().isEmpty)
    }

    /// It runs on every launch, so the second pass must be free.
    @Test("the sweep is idempotent")
    func sweepIsIdempotent() async throws {
        let (store, ingester) = try await makeStore()
        _ = try await ingester.ingest(
            title: "Call", text: "<think>reasoning about the transcript", kind: .call
        )
        #expect(try store.quarantineModelThinking().count == 1)
        #expect(try store.quarantineModelThinking().isEmpty)
        #expect(try store.allItems(kind: .quarantined).count == 1)
    }

    @Test("a corpus with nothing poisoned is left entirely alone")
    func cleanCorpusIsUntouched() async throws {
        let (store, ingester) = try await makeStore()
        _ = try await ingester.ingest(
            title: "Notes", text: "The summariser strips <think> blocks before persisting."
        )
        #expect(try store.quarantineModelThinking().isEmpty)
        #expect(try store.allItems(kind: .quarantined).isEmpty)
    }
}

/// ★ The pin that makes the duplication survivable.
///
/// `ModelThinkingQuarantine` cannot import `M1K3Inference` — M1K3Knowledge
/// deliberately takes no dependency on it — so it restates the reasoning markers
/// that `ReasoningSplit` owns. That is the SAME shape as the defect this whole
/// change is about: two copies of a marker list, one of which knew only
/// `<think>`, is how the model's own thinking got stored as knowledge for six
/// weeks.
///
/// The file's comment claimed the duplication was "pinned by test". Review
/// checked, and it was not — the claim was the protection, which is worse than
/// no claim. This is the test that makes it true.
struct ModelThinkingMarkerPinTests {
    @Test("the quarantine's markers match the split's, exactly")
    func markersMatchTheSplitter() {
        #expect(Set(ModelThinkingQuarantine.openMarkers) == Set(ReasoningSplit.openTags))
    }
}
