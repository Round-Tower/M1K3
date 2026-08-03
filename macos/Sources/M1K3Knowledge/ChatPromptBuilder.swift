//
//  ChatPromptBuilder.swift
//  M1K3Knowledge
//
//  Pure prompt assembly for grounded (RAG) chat: retrieved chunks + the user's
//  message → one prompt. Generalised from the prior knowledge-server's ChatPromptBuilder (which had a
//  domain-specific observations block); M1K3 has a single KNOWLEDGE block.
//
//  Carries the prior knowledge-server's hard-won prompt lessons forward:
//   - Documents-first: authoritative knowledge leads, then how-to-answer rules.
//   - Citation tokens, NOT markdown links — Apple Foundation Models treats bare
//     [X] as a half-formed link, so we tell it explicitly these are citations.
//   - When the knowledge doesn't cover the question, say so rather than invent.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.85,
//  Prior: internal knowledge-server project, ChatPromptBuilder.swift (Kev)
//  Review: Kev + claude-opus-4-8, 2026-06-29, Confidence 0.85 — the empty-context
//  branch unconditionally told the model to "say you found nothing in the user's
//  own documents", framing EVERY no-context turn as a failed lookup — so a
//  "write me an HTML page" got a confusing failed-lookup disclaimer. Now it
//  explicitly permits generation (write/create/code/explain are tasks to do, not
//  lookups) and keeps honest abstention only for factual questions.
//  Review: Kev + claude-opus-5, 2026-08-03, Confidence 0.9 — issue #97, both
//  symptoms of one screenshot traced here. (1) Every branch opened "You are M1K3,
//  a private local assistant", a SECOND identity contradicting the persona every
//  provider already injects as session instructions ("a curious AI living
//  entirely on your Mac"). On the live Mini path the nearer one won and M1K3
//  introduced itself as "your local AI assistant" — the one noun the design
//  doctrine forbids, on a first-run chip. Identity now lives in exactly one place.
//  (2) The citation example was rendered from chunks[0]'s REAL label, so the
//  prompt literally said "cite using citation tokens like
//  [M1K3_system_prompt_v2]" and the model echoed that string into its prose. The
//  example is now the generic `[Title §heading]` — the same shape the agent
//  path's rules already use, and the only shape CitationValidator and
//  SpeechTextPolish can see (both discriminate on §).

import Foundation

public enum ChatPromptBuilder {
    /// Build a grounded chat prompt. When `chunks` is empty, returns a
    /// no-context prompt that instructs the model to answer from general
    /// knowledge and be explicit about the lack of sources.
    public static func build(chunks: [ChunkHit], userMessage: String) -> String {
        guard !chunks.isEmpty else {
            return """
            No stored knowledge matched this question — that's fine.
            A request to write, create, code, or explain something is a task to
            do — just produce it; stored sources aren't needed for that.

            Answer from what you genuinely know. If it's a fact you don't have,
            say so plainly rather than guessing — never invent facts or sources.

            USER: \(userMessage)
            """
        }

        let knowledge = chunks.enumerated().map { index, hit in
            "\(index + 1). \(citationLabel(for: hit))\n\(hit.content)"
        }.joined(separator: "\n\n")

        return """
        Answer the user's question using the KNOWLEDGE below — the user's own
        documents, calls, and notes.

        KNOWLEDGE:
        \(knowledge)

        HOW TO ANSWER:
        - Ground your answer in the KNOWLEDGE above. If it doesn't cover the
          question, say so — do not invent facts.
        - Cite sources inline using citation tokens like [Title §heading].
          These are citation tokens, NOT markdown links — never follow them with
          parentheses or a URL.

        USER: \(userMessage)
        """
    }

    /// The bracketed label for a chunk: `[Title §heading]` or `[Title]`.
    public static func citationLabel(for hit: ChunkHit) -> String {
        if let heading = hit.heading, !heading.isEmpty {
            return "[\(hit.itemTitle) §\(heading)]"
        }
        return "[\(hit.itemTitle)]"
    }
}
