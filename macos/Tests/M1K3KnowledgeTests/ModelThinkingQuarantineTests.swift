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
