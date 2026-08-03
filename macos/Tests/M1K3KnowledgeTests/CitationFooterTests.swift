import Foundation
@testable import M1K3Knowledge
import Testing

/// The honest "Sources:" footer: of the chunks that were RETRIEVED, keep only the
/// ones the answer ACTUALLY cited (a validated [Title §heading] marker). An
/// off-topic chunk that rode above the grounding threshold on an identity turn
/// ("who are you") must NOT be stapled on as a phantom source.
struct CitationFooterTests {
    private func hit(_ title: String, _ heading: String?, similarity: Float? = nil) -> ChunkHit {
        ChunkHit(chunkID: UUID(), itemID: UUID(), itemTitle: title,
                 kind: .document, heading: heading, content: "x", similarity: similarity)
    }

    @Test("a headingless citation credits the document it names (issue #97)")
    func headinglessCitationCreditsTheDocument() {
        // CitationValidator now recognises bare `[Title]` citations against the
        // retrieved titles, so an empty-heading citation is no longer the
        // "unparseable" case this matcher was written to dismiss. Citing a
        // document without naming a section is a weaker citation, not a
        // fabricated one — it should still show its source.
        let retrieved = [hit("Plant Notes", "3.2 Seals"), hit("Field Log", nil)]
        let referenced = CitationFooter.referencedSources(
            from: retrieved, citedBy: [Citation(source: "Plant Notes", heading: "")]
        )
        #expect(referenced.map(\.itemTitle) == ["Plant Notes"])
    }

    @Test("a headingless citation credits ONE chunk per title, not every section retrieved")
    func headinglessCitationDoesNotFanOutAcrossSections() {
        // Retrieval dedups on chunkID, not title (KnowledgeStore.searchHybrid),
        // so top-K routinely returns several chunks of the SAME document with
        // different headings — the live `M1K3_system_prompt_v2` search in #97
        // returned three. Crediting a generic `[Plant Notes]` to all of them
        // renders section-specific footer lines the model never claimed, and
        // inflates the "N sources" count: phantom PRECISION, which is the same
        // class of defect this file exists to prevent as phantom sources.
        let retrieved = [
            hit("Plant Notes", "3.2 Seals", similarity: 0.9),
            hit("Plant Notes", "4.1 Valves", similarity: 0.8),
            hit("Chinchilla", "2 Scaling", similarity: 0.7),
        ]
        let referenced = CitationFooter.referencedSources(
            from: retrieved, citedBy: [Citation(source: "Plant Notes", heading: "")]
        )
        // One line for the document, and it's the highest-ranked chunk of it.
        #expect(referenced.count == 1)
        #expect(referenced.first?.heading == "3.2 Seals")
    }

    @Test("a heading-bearing citation still credits its exact section alongside a generic one")
    func headinglessCitationDoesNotSuppressAnExactOne() {
        // The generic-citation collapse must not swallow a section the model
        // DID name: cite the doc generically AND 4.1 explicitly → 4.1 is kept
        // on its own merits, and the generic citation adds no second line for
        // a title already represented.
        let retrieved = [
            hit("Plant Notes", "3.2 Seals", similarity: 0.9),
            hit("Plant Notes", "4.1 Valves", similarity: 0.8),
        ]
        let referenced = CitationFooter.referencedSources(
            from: retrieved,
            citedBy: [
                Citation(source: "Plant Notes", heading: ""),
                Citation(source: "Plant Notes", heading: "4.1 Valves"),
            ]
        )
        #expect(referenced.map(\.heading) == ["4.1 Valves"])
    }

    @Test("a headingless citation never credits a different document")
    func headinglessCitationStaysTitleScoped() {
        let retrieved = [hit("Plant Notes", "3.2 Seals")]
        let referenced = CitationFooter.referencedSources(
            from: retrieved, citedBy: [Citation(source: "Field Log", heading: "")]
        )
        #expect(referenced.isEmpty)
    }

    @Test("an identity turn that cited nothing yields an empty footer")
    func nothingCitedDropsEverything() {
        // Two off-topic chunks cleared the gate, but the answer cited none of them.
        let retrieved = [hit("Chinchilla", "2 Scaling"), hit("Chain of Thought", "3 Prompting")]
        let referenced = CitationFooter.referencedSources(from: retrieved, citedBy: [])
        #expect(referenced.isEmpty)
    }

    @Test("keeps only the retrieved chunk the answer actually cited")
    func keepsOnlyCited() {
        let retrieved = [hit("Plant Notes", "3.2 Seals"), hit("Chinchilla", "2 Scaling")]
        let cited = [Citation(source: "Plant Notes", heading: "3.2 Seals")]
        let referenced = CitationFooter.referencedSources(from: retrieved, citedBy: cited)
        #expect(referenced.map(\.itemTitle) == ["Plant Notes"])
    }

    @Test("citation casing differing from the chunk still matches (renders from the chunk)")
    func caseInsensitiveMapping() {
        let retrieved = [hit("Plant Notes", "3.2 Seals")]
        // The model recased the title/heading when echoing the marker.
        let cited = [Citation(source: "plant notes", heading: "3.2 seals")]
        let referenced = CitationFooter.referencedSources(from: retrieved, citedBy: cited)
        // Survives, and carries the chunk's verbatim casing for rendering.
        #expect(referenced.map(\.itemTitle) == ["Plant Notes"])
        #expect(referenced.first?.heading == "3.2 Seals")
    }

    @Test("input relevance order is preserved among the kept chunks")
    func preservesOrder() {
        let retrieved = [
            hit("Alpha", "1", similarity: 0.9),
            hit("Beta", "2", similarity: 0.8),
            hit("Gamma", "3", similarity: 0.7),
        ]
        let cited = [
            Citation(source: "Gamma", heading: "3"),
            Citation(source: "Alpha", heading: "1"),
        ]
        let referenced = CitationFooter.referencedSources(from: retrieved, citedBy: cited)
        // Order follows the retrieved list (relevance), not the citation order.
        #expect(referenced.map(\.itemTitle) == ["Alpha", "Gamma"])
    }

    @Test("a chunk with no heading is never kept by a heading-bearing citation")
    func nilHeadingChunkNotMatched() {
        let retrieved = [hit("Loose Note", nil)]
        let cited = [Citation(source: "Loose Note", heading: "1 Intro")]
        let referenced = CitationFooter.referencedSources(from: retrieved, citedBy: cited)
        #expect(referenced.isEmpty)
    }

    @Test("a cited title with a non-matching heading is not kept")
    func headingMustAlsoMatch() {
        let retrieved = [hit("Plant Notes", "3.2 Seals")]
        let cited = [Citation(source: "Plant Notes", heading: "9.9 Wrong")]
        let referenced = CitationFooter.referencedSources(from: retrieved, citedBy: cited)
        #expect(referenced.isEmpty)
    }

    @Test("a .memory hit is never kept even if a citation matches it (ambient, do not cite)")
    func memoryNeverCited() {
        // Memories are "use naturally, do not cite" context. The exclusion lives
        // here so HeadlessAsk and MessageView share one rule (no asymmetry).
        let memory = ChunkHit(chunkID: UUID(), itemID: UUID(), itemTitle: "User Facts",
                              kind: .memory, heading: "Mac", content: "The user has a Mac.")
        let doc = hit("Plant Notes", "3.2 Seals")
        let cited = [
            Citation(source: "User Facts", heading: "Mac"),
            Citation(source: "Plant Notes", heading: "3.2 Seals"),
        ]
        let referenced = CitationFooter.referencedSources(from: [memory, doc], citedBy: cited)
        #expect(referenced.map(\.itemTitle) == ["Plant Notes"])
    }
}
