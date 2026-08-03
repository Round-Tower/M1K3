//
//  ChatPromptBuilderTests.swift
//  M1K3KnowledgeTests
//
//  Contract tests for the pure RAG prompt builder: knowledge block, citation
//  framing, the empty-context path, and the citation label format.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.9, Prior: Unknown

import Foundation
@testable import M1K3Knowledge
import Testing

struct ChatPromptBuilderTests {
    private func hit(_ title: String, _ heading: String?, _ content: String) -> ChunkHit {
        ChunkHit(
            chunkID: UUID(), itemID: UUID(), itemTitle: title,
            kind: .document, heading: heading, content: content
        )
    }

    @Test("includes the knowledge, the user message, and citation framing")
    func grounded() {
        let prompt = ChatPromptBuilder.build(
            chunks: [hit("Plant Notes", "3.2 Seals", "The hydraulic seal failed.")],
            userMessage: "What failed?"
        )
        #expect(prompt.contains("KNOWLEDGE:"))
        #expect(prompt.contains("The hydraulic seal failed."))
        #expect(prompt.contains("[Plant Notes §3.2 Seals]"))
        #expect(prompt.contains("USER: What failed?"))
        // The Apple-FM lesson must be present.
        #expect(prompt.contains("NOT markdown links"))
    }

    @Test("empty knowledge produces a no-context prompt that admits the gap")
    func emptyContext() {
        let prompt = ChatPromptBuilder.build(chunks: [], userMessage: "Anything on seals?")
        #expect(prompt.contains("No stored knowledge matched"))
        #expect(prompt.contains("USER: Anything on seals?"))
        #expect(!prompt.contains("KNOWLEDGE:"))
    }

    @Test("empty-knowledge fallback biases to honest abstention, not a confab licence")
    func emptyContextDiscouragesGuessing() {
        // This prompt feeds the agent-loop fallback and the plain RAGResponder.
        // The old "Answer from general knowledge if you can" read as licence to
        // invent on a weak model — align it with the anti-confab stance the
        // grounding body carries everywhere else.
        let prompt = ChatPromptBuilder.build(chunks: [], userMessage: "q")
        #expect(!prompt.contains("Answer from general knowledge if you can"))
        // The prompt wraps across lines, so match within a line.
        #expect(prompt.contains("Answer from what you"))
        #expect(prompt.contains("say so plainly rather than"))
    }

    @Test("the no-context prompt permits generation and drops the failed-lookup framing")
    func emptyContextPermitsGeneration() {
        let prompt = ChatPromptBuilder.build(chunks: [], userMessage: "write me an HTML page")
        // No more "found nothing in your documents" stapled onto a generative ask.
        #expect(!prompt.lowercased().contains("found nothing"))
        // Generation is explicitly licensed.
        #expect(prompt.contains("write, create, code, or explain"))
        // Honest abstention survives — for factual questions only.
        #expect(prompt.contains("never invent facts or sources"))
    }

    @Test("citation label includes heading when present, omits when absent")
    func citationLabel() {
        #expect(ChatPromptBuilder.citationLabel(for: hit("Doc", "1.1 A", "x")) == "[Doc §1.1 A]")
        #expect(ChatPromptBuilder.citationLabel(for: hit("Doc", nil, "x")) == "[Doc]")
        #expect(ChatPromptBuilder.citationLabel(for: hit("Doc", "", "x")) == "[Doc]")
    }

    // MARK: - Identity and citation framing (issue #97)

    @Test("the per-turn body never restates M1K3's identity — the persona owns it")
    func doesNotAssertACompetingIdentity() {
        // Every provider path injects M1K3Persona as the SESSION instructions
        // (AppleFoundationModelsProvider / MLXGemmaProvider `instructions:`, the
        // native system turn, the ReAct prepend). This builder produced a SECOND,
        // contradicting identity in the per-turn body — "a private local
        // assistant" against the persona's "a curious AI living entirely on your
        // Mac" — and on the live Mini path the nearer one won: M1K3 introduced
        // itself as "your local AI assistant" (#97). Identity belongs in exactly
        // one place; per-turn content carries the task, not the character.
        for prompt in [
            ChatPromptBuilder.build(chunks: [hit("Doc", nil, "x")], userMessage: "q"),
            ChatPromptBuilder.build(chunks: [], userMessage: "q"),
        ] {
            #expect(!prompt.contains("You are M1K3"))
            #expect(!prompt.lowercased().contains("assistant"))
        }
    }

    @Test("the citation example is a generic shape, never a retrieved title")
    func citationExampleIsGenericNotARetrievedTitle() {
        // The example was rendered from chunks[0]'s REAL label, so the prompt read
        // "cite using citation tokens like [M1K3_system_prompt_v2]" — and the model
        // dutifully echoed that exact string into its prose with nothing to cite
        // (#97, screenshot-proven). Demonstrate the FORM, never a live title.
        let prompt = ChatPromptBuilder.build(
            chunks: [hit("Client Memo", nil, "body")], userMessage: "q"
        )
        #expect(prompt.contains("[Title §heading]"))
        // The real label appears once — in the KNOWLEDGE block — and never again
        // as the thing the model is told to imitate.
        #expect(prompt.components(separatedBy: "[Client Memo]").count - 1 == 1)
    }

    @Test("the citation example keeps the § form the validator can actually see")
    func citationExampleCarriesTheHeadingMarker() {
        // CitationValidator parses on `§` as the discriminator, so a headingless
        // `[Title]` echo is invisible to validation, to the Sources footer, and to
        // SpeechTextPolish (it gets read aloud). Steering the model to the § form
        // keeps every downstream consumer able to see what it emits.
        let prompt = ChatPromptBuilder.build(chunks: [hit("Doc", nil, "x")], userMessage: "q")
        #expect(prompt.contains("§"))
    }

    @Test("numbers multiple chunks in order")
    func numbered() {
        let prompt = ChatPromptBuilder.build(
            chunks: [hit("A", nil, "first"), hit("B", nil, "second")],
            userMessage: "q"
        )
        #expect(prompt.contains("1. [A]"))
        #expect(prompt.contains("2. [B]"))
    }
}
