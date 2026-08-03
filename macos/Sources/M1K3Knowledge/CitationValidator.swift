//
//  CitationValidator.swift
//  M1K3Knowledge
//
//  Post-validates `[SOURCE §heading]` / `(SOURCE §heading)` citations in a model
//  response against what's actually indexed. Strips the ones the model invented
//  and reports them separately so an audit trail can record fabrication.
//
//  Generalised from the prior knowledge-server's CitationValidator: the existence check is *injected*
//  (a predicate) rather than hard-wired to the store, so the parsing/stripping
//  logic is pure and testable with no database. A store-backed predicate wires
//  in at the call site.
//
//  Both delimiters are accepted because Apple Foundation Models renders
//  citations as parentheticals `(ICH-Q7 §5.2 …)` in flowing prose even when the
//  prompt example uses brackets — and `[X]` reads to the model as a half-formed
//  markdown link. Accepting either keeps the audit honest without fighting style.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.85,
//  Prior: internal knowledge-server project, CitationValidator.swift (Kev)
//  Review: Kev + claude-fable-5, 2026-06-12, Confidence 0.9 — patterns
//  broadened from single-token ALL-CAPS sources to any-title-before-§
//  (citationLabel renders titles verbatim, so real citations were invisible
//  to validation and hallucinated ones leaked); markdown-link lookahead;
//  case-insensitive chunk comparison so casing deviations aren't stripped.

import Foundation

/// A citation reference parsed from model output: a source token (e.g.
/// "ICH-Q7") and the cited heading.
public struct Citation: Sendable, Equatable, Hashable, Codable {
    public let source: String
    public let heading: String

    public init(source: String, heading: String) {
        self.source = source
        self.heading = heading
    }
}

public enum CitationValidator {
    public struct Result: Sendable, Equatable {
        public let cleanedText: String
        public let validated: [Citation]
        public let stripped: [Citation]

        public init(cleanedText: String, validated: [Citation], stripped: [Citation]) {
            self.cleanedText = cleanedText
            self.validated = validated
            self.stripped = stripped
        }
    }

    /// Parse all citations in `responseText`, validate each via `exists`, strip
    /// the hallucinated ones from the text, and report the breakdown. Each
    /// distinct (source, heading) is checked once even if cited repeatedly.
    public static func validate(
        responseText: String,
        exists: @Sendable (Citation) async -> Bool
    ) async -> Result {
        var validated: [Citation] = []
        var stripped: [Citation] = []
        var cleanedText = responseText
        var processed: Set<Citation> = []

        for hit in citationHits(in: responseText) {
            if processed.contains(hit.citation) { continue }
            processed.insert(hit.citation)

            if await exists(hit.citation) {
                validated.append(hit.citation)
            } else {
                stripped.append(hit.citation)
                cleanedText = cleanedText.replacingOccurrences(of: hit.full, with: "")
            }
        }

        return Result(cleanedText: cleanedText, validated: validated, stripped: stripped)
    }

    /// Validate against the retrieved chunks — the RAG grounding contract: a citation
    /// is kept iff some chunk shares its title (source) and heading. The model may only
    /// cite what it was shown, so a citation to un-retrieved content is stripped even if
    /// that content exists elsewhere in the store.
    public static func validate(
        responseText: String,
        against chunks: [ChunkHit]
    ) async -> Result {
        // Case-insensitive: the model was SHOWN the exact-case label, but a
        // casing deviation when echoing it is not a hallucination — stripping
        // "[PLANT NOTES §…]" because the chunk says "Plant Notes" removes a
        // correct grounding affordance.
        let result = await validate(responseText: responseText) { citation in
            chunks.contains { chunk in
                chunk.itemTitle.compare(citation.source, options: .caseInsensitive) == .orderedSame
                    && (chunk.heading?.trimmingCharacters(in: .whitespaces) ?? "")
                    .compare(citation.heading, options: .caseInsensitive) == .orderedSame
            }
        }
        // Headingless `[Title]` labels (what citationLabel renders for a chunk
        // with no heading) carry no §, so the parser above cannot see them —
        // they were never validated, never credited to the Sources footer, and
        // never stripped. Recognise them here, where the retrieved titles are
        // known: a bracket is a citation ONLY when it names a title actually
        // retrieved this turn. Everything else stays untouched prose.
        let extra = headinglessCitations(in: responseText, chunks: chunks)
            .filter { !result.validated.contains($0) }
        let validated = result.validated + extra
        // Stripping a citation leaves a gap ("…not  ." / "see  and"); tidy it so the
        // cleaned answer reads naturally in the UI (this overload feeds the rendered text).
        guard !result.stripped.isEmpty else {
            return Result(
                cleanedText: result.cleanedText, validated: validated, stripped: result.stripped
            )
        }
        return Result(
            cleanedText: tidy(result.cleanedText),
            validated: validated,
            stripped: result.stripped
        )
    }

    /// Headingless citations — `[Title]` with no § — restricted to titles that
    /// were actually retrieved this turn.
    ///
    /// Title-only matching is deliberate: citing the document without naming a
    /// section is a weaker citation, not a fabricated one, so a chunk that HAS
    /// a heading still answers to a bare `[Title]`.
    ///
    /// The allowlist is the whole safety argument. These are never stripped and
    /// an unrecognised bracket is never even parsed, because bare brackets are
    /// overwhelmingly ordinary text — `[String]` in a code block, `[1]`
    /// footnotes, `[sic]`. The trade is that a FABRICATED headingless citation
    /// survives unchecked; the § form keeps full fabrication checking, and the
    /// prompt only ever demonstrates the § form (see ChatPromptBuilder).
    static func headinglessCitations(in text: String, chunks: [ChunkHit]) -> [Citation] {
        guard !chunks.isEmpty else { return [] }
        // Same markdown-link exemption as the § parser: "[label](url)" is a link.
        let pattern = #/\[([^\[\]§\n]+)\](?!\()/#
        var found: [Citation] = []
        for match in text.matches(of: pattern) {
            let source = match.1.trimmingCharacters(in: .whitespaces)
            guard chunks.contains(where: {
                $0.itemTitle.compare(source, options: .caseInsensitive) == .orderedSame
            }) else { continue }
            let citation = Citation(source: source, heading: "")
            if !found.contains(citation) { found.append(citation) }
        }
        return found
    }

    /// Collapse the whitespace a stripped citation leaves behind: runs of spaces → one,
    /// no space before sentence punctuation, trimmed ends. Newlines are preserved.
    static func tidy(_ text: String) -> String {
        var cleaned = text
        while cleaned.contains("  ") {
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        }
        for mark in [".", ",", ";", ":", "!", "?"] {
            cleaned = cleaned.replacingOccurrences(of: " \(mark)", with: mark)
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Parsing

    struct Hit: Equatable {
        let full: String
        let citation: Citation
    }

    /// Extract every bracket- and paren-delimited citation, in document order
    /// (brackets first, then parens — matching the prior knowledge-server's collection order).
    static func citationHits(in text: String) -> [Hit] {
        // The § is the discriminator (the same rule SpeechTextPolish strips
        // by) — titles match VERBATIM as citationLabel renders them, mixed
        // case and spaces included. The old single-token ALL-CAPS source
        // ([A-Z][A-Z0-9-]+) couldn't even parse "[Plant Notes §…]", so real
        // titles bypassed validation and hallucinated citations leaked into
        // the rendered answer.
        // The (?!\() lookahead exempts markdown links — "[see §5](url)" is a
        // link whose text happens to contain §, and stripping its bracket
        // half would leave "(url)" dangling. A citation followed by paren
        // PROSE ("[Title §h] (aside)") has a space first, so it still parses.
        let bracketPattern = #/\[([^\[\]§\n]+?)\s+§([^\]\n]+)\](?!\()/#
        let parenPattern = #/\(([^()§\n]+?)\s+§([^()\n]+)\)/#

        var hits: [Hit] = []
        for match in text.matches(of: bracketPattern) {
            hits.append(makeHit(full: match.0, source: match.1, heading: match.2))
        }
        for match in text.matches(of: parenPattern) {
            hits.append(makeHit(full: match.0, source: match.1, heading: match.2))
        }
        return hits
    }

    private static func makeHit(
        full: Substring,
        source: Substring,
        heading: Substring
    ) -> Hit {
        Hit(
            full: String(full),
            citation: Citation(
                source: source.trimmingCharacters(in: .whitespaces),
                heading: heading.trimmingCharacters(in: .whitespaces)
            )
        )
    }
}
