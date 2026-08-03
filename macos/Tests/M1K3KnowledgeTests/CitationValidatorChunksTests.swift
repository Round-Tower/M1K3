import Foundation
@testable import M1K3Knowledge
import Testing

/// Tests the RAG-grounding overload: citations are validated against the retrieved
/// chunks (the model may only cite what it was shown), not the whole store.
struct CitationValidatorChunksTests {
    private func hit(_ title: String, _ heading: String?) -> ChunkHit {
        ChunkHit(chunkID: UUID(), itemID: UUID(), itemTitle: title,
                 kind: .document, heading: heading, content: "x")
    }

    // MARK: - Headingless citations (issue #97)

    @Test("a headingless citation to a retrieved chunk is recognised and credited")
    func headinglessCitationToARetrievedChunkValidates() async {
        // `citationLabel` renders a chunk with no heading as bare `[Title]`, but
        // the parser discriminates on §, so those labels were invisible to
        // validation: never checked, never credited, never stripped. A grounded
        // answer that cited a headingless doc therefore showed NO source footer
        // (CitationFooter keys off `validated`) while the raw token sat in the
        // prose looking like debug output — exactly the `[M1K3_system_prompt_v2]`
        // that landed in Kev's bubble (#97).
        let chunks = [hit("Field Log", nil)]
        let result = await CitationValidator.validate(
            responseText: "The pump was replaced in March [Field Log].", against: chunks
        )
        #expect(result.validated == [Citation(source: "Field Log", heading: "")])
        #expect(result.stripped.isEmpty)
        // Kept in the prose, exactly as a `[Title §heading]` citation is.
        #expect(result.cleanedText.contains("[Field Log]"))
    }

    @Test("a headingless bracket matches a retrieved title even when that chunk has a heading")
    func headinglessCitationMatchesOnTitleAlone() async {
        // Citing the document without naming a section is a legitimate, weaker
        // citation — not a fabrication. Match on title alone here, or the
        // recognition above would strip it for a heading it never claimed.
        let chunks = [hit("Plant Notes", "3.2 Seals")]
        let result = await CitationValidator.validate(
            responseText: "See [Plant Notes].", against: chunks
        )
        #expect(result.validated == [Citation(source: "Plant Notes", heading: "")])
        #expect(result.stripped.isEmpty)
    }

    /// Deliberate boundary (a decision, not an oversight): a bracket that does
    /// NOT name a retrieved title is left completely alone — never parsed,
    /// never stripped. Bare brackets are overwhelmingly ordinary text —
    /// `[String]` in a Swift snippet, `[1]` footnotes, `[sic]` — and stripping
    /// unknown ones would mangle code the markdown renderer is now shipping
    /// (#93). The cost is that a fabricated headingless citation survives;
    /// the § form remains the one that gets full fabrication checking.
    @Test("brackets that name no retrieved chunk are left untouched")
    func unknownBracketsAreNotTreatedAsCitations() async {
        let chunks = [hit("Field Log", nil)]
        let text = "Use `let names: [String] = []` — see note [1], and [sic] stands."
        let result = await CitationValidator.validate(responseText: text, against: chunks)
        #expect(result.validated.isEmpty)
        #expect(result.stripped.isEmpty)
        #expect(result.cleanedText == text)
    }

    @Test("keeps citations that match a retrieved chunk, strips the invented ones")
    func validatesAgainstChunks() async {
        let chunks = [hit("ICH-Q7", "5.2 Cleaning"), hit("Plant Notes", "3.2 Seals")]
        let text = "Follow (ICH-Q7 §5.2 Cleaning) and [FAKE §9.9 Nope]."
        let result = await CitationValidator.validate(responseText: text, against: chunks)
        #expect(result.validated == [Citation(source: "ICH-Q7", heading: "5.2 Cleaning")])
        #expect(result.stripped == [Citation(source: "FAKE", heading: "9.9 Nope")])
        #expect(!result.cleanedText.contains("FAKE"))
        #expect(result.cleanedText.contains("ICH-Q7"))
    }

    @Test("a citation whose heading doesn't match its chunk is stripped")
    func headingMismatchStripped() async {
        let chunks = [hit("ICH-Q7", "5.2 Cleaning")]
        let result = await CitationValidator.validate(
            responseText: "See (ICH-Q7 §9.9 Wrong).", against: chunks
        )
        #expect(result.validated.isEmpty)
        #expect(result.stripped == [Citation(source: "ICH-Q7", heading: "9.9 Wrong")])
    }

    @Test("no chunks ⇒ every citation is stripped")
    func noChunksStripsAll() async {
        let result = await CitationValidator.validate(
            responseText: "Per (ABC §1 Intro).", against: []
        )
        #expect(result.validated.isEmpty)
        #expect(result.stripped.count == 1)
    }

    @Test("stripping tidies the gap it leaves — no double space, no space before punctuation")
    func stripTidiesWhitespace() async {
        let result = await CitationValidator.validate(
            responseText: "Clean it but not [FAKE §9 Nope]. Then rinse.", against: []
        )
        #expect(result.cleanedText == "Clean it but not. Then rinse.")
        #expect(!result.cleanedText.contains("  "))
    }

    @Test("title-case deviations from the model don't strip a real citation")
    func caseInsensitiveAgainstChunks() async {
        // The model was shown "[Plant Notes §3.2 Seals]"; echoing it upper-cased
        // is a casing deviation, not a hallucination — stripping it would
        // remove a CORRECT grounding affordance.
        let chunks = [hit("Plant Notes", "3.2 Seals")]
        let result = await CitationValidator.validate(
            responseText: "See [PLANT NOTES §3.2 SEALS].", against: chunks
        )
        #expect(result.stripped.isEmpty)
        #expect(result.validated.count == 1)
    }

    @Test("a citation cited twice is reported once and removed everywhere")
    func deduplicatesRepeatedCitation() async {
        let result = await CitationValidator.validate(
            responseText: "[FAKE §1 A] said it; later [FAKE §1 A] again.", against: []
        )
        #expect(result.stripped == [Citation(source: "FAKE", heading: "1 A")])
        #expect(!result.cleanedText.contains("FAKE"))
    }
}
