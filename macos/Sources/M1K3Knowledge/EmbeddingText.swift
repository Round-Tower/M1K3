//
//  EmbeddingText.swift
//  M1K3Knowledge
//
//  B5 layer 3 — what a chunk is embedded AS. A chunk's discriminating context
//  often lives in the document TITLE ("Golden Gate derisk") while the body is
//  generic; embedding bare content left that context invisible to the vector
//  (the milestone memory measured 0.286 against its own query — under every
//  floor). Chunks now embed title-prefixed, at ingest AND reindex, through
//  this one composition point.
//
//  Two rules keep it honest:
//  - Content that already LEADS with its title (memory facts are their own
//    titles, including the word-boundary "…" truncation) embeds bare — no
//    doubled text shifting the fact lane.
//  - The composition is versioned into the store fingerprint, so changing it
//    triggers the same one-time corpus re-embed an embedder swap does; mixed
//    composition in one store would compare incompatible vectors forever.
//
//  Queries embed as typed (asymmetric on purpose): the title is document-side
//  context, not something a user would type twice.
//
//  Signed: Kev + claude-fable-5, 2026-07-08, Confidence 0.85 (composition
//  pinned by tests; the retrieval delta + ABSEP/MEMEVAL threshold re-check is
//  the named on-device verify — layer 3's doctrine is measured, not guessed).
//  Prior: Unknown
//  Review: Kev + claude-fable-5, 2026-07-09 — added `forQuery`, the
//  Qwen3-Embedding asymmetric query instruction (measurement-first: KEYEVAL
//  measures it before any call site adopts it). Doc-side composition and the
//  fingerprint salt are untouched. Confidence 0.85.
//  Review: Kev + claude-fable-5.1, 2026-10-10 — `forGemmaQuery` / `forGemmaDocument`, EmbeddingGemma 2's
//  card prompts (Stream C slice 2); the Qwen composer and the salt are untouched. Confidence 0.85.
//

import Foundation

public enum EmbeddingText {
    /// Versioned composition identity, salted into the store's embedder
    /// fingerprint. Bump when `forChunk` changes shape.
    public static let compositionVersion = "title-v1"

    /// The text a chunk is embedded as: title-prefixed unless the content
    /// already leads with the title (case-insensitive; a trailing "…" from
    /// word-boundary truncation is ignored) or the title is empty. "Leads
    /// with" requires a word boundary after the match — "Cork" is not the
    /// head of "Corker Ltd…" (the review-caught silent-skip class).
    public static func forChunk(title: String, content: String) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return content }
        var head = trimmedTitle
        if head.hasSuffix("…") { head = String(head.dropLast()) }
        head = head.trimmingCharacters(in: .whitespaces)
        if !head.isEmpty, content.lowercased().hasPrefix(head.lowercased()),
           wordBoundaryFollows(head: head, in: content)
        {
            return content
        }
        return "\(trimmedTitle)\n\(content)"
    }

    /// True when the content ends exactly at the head, or the character right
    /// after it is not alphanumeric — so a title matching mid-word never
    /// counts as the content's own head.
    private static func wordBoundaryFollows(head: String, in content: String) -> Bool {
        guard content.count > head.count else { return true }
        let next = content[content.index(content.startIndex, offsetBy: head.count)]
        return !(next.isLetter || next.isNumber)
    }

    /// The text a QUERY is embedded as by an instruction-aware embedder —
    /// Qwen3-Embedding's official asymmetric convention (card-verbatim,
    /// including NO space after "Query:"): queries carry the retrieval
    /// instruction, documents embed bare. Purely query-side: it never touches
    /// stored vectors, so it does NOT salt the store fingerprint and adopting
    /// it triggers no corpus re-embed.
    ///
    /// ⚠️ Changing this string re-opens the retrieval-floor calibration:
    /// every query→content cosine shifts with it, and the GroundingGate
    /// floors were derived from measured distributions. Re-run
    /// M1K3_SELFTEST_KEYEVAL and re-derive the floors before shipping any
    /// edit here — there is no CI signal for this (metallib wall).
    public static func forQuery(_ query: String) -> String {
        "Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery:\(query)"
    }

    /// The fingerprint recorded with (and compared against) the store's
    /// vectors: the embedder's own identity plus the composition version —
    /// either changing means the stored vectors are no longer comparable.
    public static func storeFingerprint(embedder fingerprint: String) -> String {
        "\(fingerprint)+\(compositionVersion)"
    }
}

// MARK: - EmbeddingGemma 2 prompts

public extension EmbeddingText {
    /// EmbeddingGemma 2's model-card prompts (`config_sentence_transformers.json`,
    /// `Retrieval-query` / `Retrieval-document`). Unlike Qwen3-Embedding, BOTH
    /// sides carry a prefix, so the document one changes stored vectors — it is
    /// tied to the model id, which the embedder fingerprint already carries, so
    /// it needs no extra salt.
    static let gemmaQueryPrefix = "task: search result | query: "
    static let gemmaDocumentPrefix = "title: none | text: "

    static func forGemmaQuery(_ query: String) -> String {
        gemmaQueryPrefix + query
    }

    static func forGemmaDocument(_ document: String) -> String {
        gemmaDocumentPrefix + document
    }
}
