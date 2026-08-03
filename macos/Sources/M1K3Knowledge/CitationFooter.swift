//
//  CitationFooter.swift
//  M1K3Knowledge
//
//  The honest "Sources:" footer. Retrieval is promiscuous by design — top-K plus
//  a grounding-gate floor (0.51 at the time) lets an off-topic chunk ride above the bar (the
//  documented sourdough/Chain-of-Thought leak), and on an identity turn ("who are
//  you") the model answers from persona and cites nothing at all. Rendering the
//  footer from what was RETRIEVED therefore staples phantom sources onto answers
//  that never used them — a real honesty defect for a local-first assistant.
//
//  This keeps only the retrieved chunks the answer ACTUALLY cited: a validated
//  `[Title §heading]` marker (CitationValidator already computes that set and the
//  callers already throw it away). Source of truth = the model's validated
//  citations, not retrieval. An identity turn validly cites nothing → empty footer;
//  a grounded answer validly cites its doc → that source survives. The one trade:
//  a grounded answer that FORGETS its marker shows no footer — more honest than
//  inventing provenance, and the CHATEVAL `mustCite` fixtures are the regression
//  alarm if marker-emission ever gets flaky.
//
//  Signed: claude-opus-4-8, 2026-06-20, Confidence 0.88, Prior: Unknown
//  (Design challenged: Option A "intersect, don't replace" chosen over content-
//   overlap (re-derives GroundingGate) and short-query thresholds (band-aid).
//   Shared here so HeadlessAsk AND ChatSession apply one rule.)

import Foundation

public enum CitationFooter {
    /// Of the retrieved `hits`, return only those the answer cited via a validated
    /// citation (`validated` from `CitationValidator.Result`). Matching is
    /// case-insensitive on title + heading (the model may recase what it echoes),
    /// but the returned chunks carry their VERBATIM casing for rendering. Input
    /// order (relevance) is preserved. Nothing cited ⇒ empty (no phantom sources).
    ///
    /// `.memory` hits are excluded here as a single shared rule — memories are
    /// ambient "use naturally, do not cite" context, never citation sources — so
    /// every caller (HeadlessAsk footer, MessageView disclosure) is provably
    /// equivalent rather than each re-deriving the exclusion.
    ///
    /// Note: matching is exact (case-insensitive) on title AND heading, mirroring
    /// CitationValidator. A model that rephrases a heading ("§3.2" vs the chunk's
    /// "§3.2 Seals") won't match — but CitationValidator would have stripped that
    /// citation upstream too, so the surfaces stay consistent.
    /// A document-level citation (empty heading, `[Title]`) credits ONE chunk of
    /// that title, not every section retrieved. Retrieval dedups on chunkID, not
    /// title (`KnowledgeStore.searchHybrid`), so top-K routinely carries several
    /// chunks of the same document under different headings — the live
    /// `M1K3_system_prompt_v2` search in #97 returned three. Crediting a generic
    /// citation to all of them renders section-specific footer lines the model
    /// never claimed and inflates the "N sources" count: phantom PRECISION,
    /// which is the same honesty defect as a phantom source. A section the model
    /// DID name is still kept on its own merits.
    public static func referencedSources(
        from hits: [ChunkHit],
        citedBy validated: [Citation]
    ) -> [ChunkHit] {
        guard !validated.isEmpty else { return [] }
        let citable = hits.filter { $0.kind != .memory }
        // Exact (heading-bearing) citations first — they are the strongest claim
        // and always earn their own line.
        let exact = validated.filter { !$0.heading.isEmpty }
        var kept = Set(
            citable.filter { hit in exact.contains { cites(hit, $0) } }.map(\.chunkID)
        )
        // Then one representative per generically-cited title, skipping titles a
        // named section already speaks for. `citable` is in relevance order, so
        // `first` is the highest-ranked chunk of that document.
        let titlesAlreadyKept = citable.filter { kept.contains($0.chunkID) }.map(\.itemTitle)
        for citation in validated where citation.heading.isEmpty {
            let alreadySpokenFor = titlesAlreadyKept.contains {
                $0.compare(citation.source, options: .caseInsensitive) == .orderedSame
            }
            guard !alreadySpokenFor else { continue }
            if let representative = citable.first(where: { cites($0, citation) }) {
                kept.insert(representative.chunkID)
            }
        }
        return citable.filter { kept.contains($0.chunkID) }
    }

    /// True when `citation` refers to `hit` — same title and same heading,
    /// case-insensitively.
    ///
    /// An EMPTY heading is the document-level citation (`[Title]`, what
    /// `citationLabel` renders for a chunk with no heading). Those used to be
    /// unparseable, so this matcher could dismiss them; since #97
    /// CitationValidator recognises them against the retrieved titles, and
    /// citing a document without naming a section is a weaker citation, not a
    /// fabricated one. So an empty-heading citation matches on title alone —
    /// exactly the rule the validator used to accept it.
    private static func cites(_ hit: ChunkHit, _ citation: Citation) -> Bool {
        guard hit.itemTitle.compare(citation.source, options: .caseInsensitive) == .orderedSame
        else { return false }
        guard !citation.heading.isEmpty else { return true }
        let hitHeading = (hit.heading ?? "").trimmingCharacters(in: .whitespaces)
        return hitHeading.compare(citation.heading, options: .caseInsensitive) == .orderedSame
    }
}
