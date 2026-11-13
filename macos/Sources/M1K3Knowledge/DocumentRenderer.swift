//
//  DocumentRenderer.swift
//  M1K3Knowledge
//
//  The one "render a stored document as text" policy, shared by the MCP
//  get_document handler and the agent's GetDocumentTool: heading-aware body,
//  an explicit note for chunkless (title-only) items, and windowed paging
//  with a resume-offset footer so a multi-megabyte item can't flood a
//  caller's context (test-report F5, the firehose) — and is never silently
//  truncated either (the agent tool's old bare-ellipsis cut).
//
//  Signed: Kev + claude-fable-5, 2026-07-02, Confidence 0.9 (rendering moved
//  verbatim from KnowledgeMCPTools.getDocument, whose tests pin it; the agent
//  tool now pages instead of truncating). Prior: Kev + claude-opus-4-8
//  (KnowledgeMCPTools.getDocument).
//  Review: Kev + claude-fable-5.2, 2026-11-13 — consecutive windows of one section are stitched on
//  their overlap (`stitchedBody`), so a long item reads once: get_document printed each ~200-char
//  chunker overlap twice (found live through the Claude Code plugin). Offsets now count the stitched
//  body, so an offset saved from a footer BEFORE this change lands a little late in the same item.
//  Confidence 0.85 (pinned in DocumentRendererTests against the real chunker's windows).
//

import Foundation

/// Renders a stored knowledge item as paged text.
public enum DocumentRenderer {
    /// Default character window per call. Generous enough for a whole short
    /// paper, bounded so one item can't flood a context window in one shot.
    public static let defaultMaxChars = 6000

    public static func render(
        title: String,
        kind: KnowledgeKind,
        chunks: [KnowledgeChunk],
        maxChars: Int = defaultMaxChars,
        offset: Int = 0
    ) -> String {
        let header = "# \(title)  [\(kind.rawValue)]"
        let body = stitchedBody(chunks)
        guard !body.isEmpty else {
            return "\(header)\n\n(No readable text — this item was indexed by title only, "
                + "with no extractable body content. Nothing to return.)"
        }

        let total = body.count
        let window = max(1, maxChars)
        let start = max(0, min(offset, total))
        let slice = String(body.dropFirst(start).prefix(window))
        let end = start + slice.count
        var out = "\(header)\n\n\(slice)"
        if end < total {
            out += "\n\n[… \(total - end) more characters. "
                + "Call get_document again with offset:\(end) to continue.]"
        } else if start > 0 {
            out += "\n\n[— end of document —]"
        }
        return out
    }

    // MARK: - Stitching

    /// The shortest shared run that counts as a window overlap. The chunker
    /// never overlaps by less than about `DocumentChunker.overlapChars` (it
    /// steps back 200 and snaps to a word start), so half of that is already
    /// generous; anything shorter is a coincidence (a rule of dashes, a repeated
    /// table row), and cutting it would lose text.
    static let minimumOverlap = DocumentChunker.overlapChars / 2

    /// The longest run searched for: the chunker's overlap plus the word it
    /// snaps back to, with room to spare.
    static let maximumOverlap = DocumentChunker.overlapChars * 2

    /// The chunks as one readable body. Consecutive windows of the SAME section
    /// are joined on their overlap, so the text reads once and the heading
    /// prints once; everything else stays a blank line apart, as before.
    static func stitchedBody(_ chunks: [KnowledgeChunk]) -> String {
        var body = ""
        var previous: KnowledgeChunk?
        for chunk in chunks {
            defer { previous = chunk }
            if let previous, previous.heading == chunk.heading,
               let remainder = remainderAfterOverlap(previous: previous.content, next: chunk.content)
            {
                body += remainder
                continue
            }
            if !body.isEmpty { body += "\n\n" }
            if let heading = chunk.heading { body += "## \(heading)\n" }
            body += chunk.content
        }
        return body
    }

    /// `next` without the prefix it shares with the end of `previous`, or nil
    /// when the two share less than `minimumOverlap` (not a window overlap).
    static func remainderAfterOverlap(previous: String, next: String) -> String? {
        let tail = Array(previous.suffix(maximumOverlap))
        let head = Array(next.prefix(maximumOverlap))
        var length = min(tail.count, head.count)
        while length >= minimumOverlap {
            // The chunker ends a window on a word boundary, so after a real overlap
            // `next` carries on with whitespace (or ends). A match that stops
            // mid-word is periodic text, not a window.
            let endsOnBoundary = length == head.count ? next.count == length : head[length].isWhitespace
            if endsOnBoundary, tail[(tail.count - length)...].elementsEqual(head[..<length]) {
                return String(next.dropFirst(length))
            }
            length -= 1
        }
        return nil
    }
}
