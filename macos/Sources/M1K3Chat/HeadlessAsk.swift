//
//  HeadlessAsk.swift
//  M1K3Chat
//
//  One headless turn through a RAGResponding for callers that aren't the
//  chat UI — today the MCP `ask_m1k3` tool. Mirrors ChatSession.send's
//  post-processing contract (fold → reasoning split → citation validation →
//  polish → merged sources) without touching any transcript: the caller owns
//  conversation state, M1K3's chat history is never written.
//
//  Run this on a DEDICATED responder instance, not the chat UI's —
//  collectedSources() is a draining read and would race a live turn.
//
//  Signed: Kev + claude-fable-5, 2026-06-11, Confidence 0.9 (contract
//  test-pinned against delta/cumulative/reasoning/citation fakes).
//  Prior: the MCP test report 2026-06-11 (F5).
//  Review: Kev + claude-opus-4-8, 2026-06-12, Confidence 0.9 — exclude
//  `.memory` hits from the Sources footer (they're "do not cite" ambient
//  context; a promiscuous short-fact embedding was rendering as a citation
//  source for unrelated queries). Validator allow-list unchanged.
//  Review: Kev + claude-opus-5, 2026-08-03, Confidence 0.9 — the "mirrors
//  ChatSession.send's post-processing contract" claim above was FALSE in one
//  step: ChatSession splits the FOLLOWUPS trailer on both its paths (send and
//  deliverBackgroundAnswer) and this one split it on neither, so every MCP
//  `ask_m1k3` answer shipped M1K3's suggestion-chip scaffolding as prose.
//  Caught live while verifying #97 over MCP. Now split in ChatSession's order —
//  before citation validation, because the trailer is not answer text.
//

import Foundation
import M1K3Inference // FollowUpSplit — the trailer is not answer text
import M1K3Knowledge

public enum HeadlessAsk {
    /// One headless turn. `canary` is the leak tripwire: any honeypot string it
    /// holds is redacted from the final answer (body + Sources footer) and
    /// `onCanaryTrip` is called with the match count so the caller can raise a
    /// loud alert. Defaults make the guard inert, so existing callers are
    /// unaffected; the MCP path supplies the real guard from non-committed config.
    public static func answer(
        _ question: String,
        using responder: any RAGResponding,
        canary: CanaryGuard = .disabled,
        onCanaryTrip: @Sendable (Int) -> Void = { _ in }
    ) async throws -> String {
        let (injected, stream) = try await responder.answerStreaming(
            question, history: [], onActivity: { _ in }
        )
        var raw = ""
        for await chunk in stream {
            raw = ChatSession.fold(raw, chunk)
        }
        let (reasoning, answerWithFollowUps) = ReasoningSplit.split(raw)
        // The FOLLOWUPS trailer is scaffolding for the chat UI's suggestion
        // chips — ChatSession strips it on both its paths, and this one claims
        // the same contract but never did, so every MCP `ask_m1k3` answer
        // carried it as prose (caught live 2026-08-03). Split BEFORE citation
        // validation, matching ChatSession.send's order: the trailer is not
        // answer text and must not be validated or polished as if it were.
        // There is nowhere to put the parsed questions here — a headless caller
        // has no chips — so they are dropped, not surfaced.
        let (answerText, _) = FollowUpSplit.split(answerWithFollowUps)
        let merged = ChatSession.mergeSources(injected, responder.collectedSources())
        let validation = await CitationValidator.validate(responseText: answerText, against: merged)
        let polished = MessageTextPolish.polish(validation.cleanedText)
        // Floor (test-report F1): the model emitted no usable answer — common on
        // the smaller brains, which reason but never conclude, so ReasoningSplit
        // reduces the turn to empty. Degrade with an honest message instead of
        // throwing; a visiting agent should never see a bare "Error: emptyAnswer".
        guard !polished.isEmpty else { return emptyAnswerMessage(didReason: reasoning != nil) }
        // The footer lists only what the answer ACTUALLY cited, not everything
        // retrieved. Top-K + the grounding floor let an off-topic chunk ride above
        // the bar; on an identity turn the model cites nothing, so rendering the
        // whole retrieval stapled phantom sources (test-report F4). `validated` is
        // the model's real citations (computed at line 47); CitationFooter keeps
        // only the hits they reference and drops ambient `.memory` context — the
        // live "The user has a Mac." leak that rode an apple-pruning turn.
        let referenced = CitationFooter.referencedSources(from: merged, citedBy: validation.validated)
        let finalText: String
        if referenced.isEmpty {
            finalText = polished
        } else {
            finalText = polished + "\n\nSources:\n" + sourceLines(referenced).joined(separator: "\n")
        }
        // Leak tripwire: redact any planted honeypot that reached the outgoing
        // text (body or footer) and raise the alert. Inert unless a real guard
        // is supplied. The canned empty-answer floor above is a constant, so it
        // skips the scan.
        return tripwired(finalText, canary: canary, onCanaryTrip: onCanaryTrip)
    }

    /// Scan the outgoing answer for honeypot strings; redact + alert if any hit.
    private static func tripwired(
        _ text: String, canary: CanaryGuard, onCanaryTrip: @Sendable (Int) -> Void
    ) -> String {
        let scan = canary.scan(text)
        if scan.tripped { onCanaryTrip(scan.count) }
        return scan.text
    }

    /// Honest degradation when the turn yields no answer. `didReason` separates
    /// the two real cases: the model thought but never concluded (the common
    /// small-brain failure), vs it produced nothing at all. Brain-agnostic on
    /// purpose — the caller may already be on the largest brain.
    static func emptyAnswerMessage(didReason: Bool) -> String {
        didReason
            ? "I worked through that but didn't reach a clear answer — try asking it "
            + "as a more direct or specific question."
            : "I wasn't able to produce an answer to that — try rephrasing it more specifically."
    }

    /// Render the Sources block: most-relevant first, no repeats.
    ///
    /// The merged hits are whatever cleared the grounding gate plus anything the
    /// tools collected — top-K retrieval, so the same item can appear several
    /// times and an off-topic-but-above-threshold chunk can ride along
    /// (test-report F4). This is a presentation pass only — it never changes what
    /// the model read, just what the caller is told it read: sort by vector
    /// similarity descending (unscored hits last, stable), then drop duplicate
    /// rendered lines. The deeper per-query relevance tuning is GroundingGate's
    /// own follow-up, not this surface's job.
    static func sourceLines(_ hits: [ChunkHit]) -> [String] {
        let ranked = hits.enumerated().sorted { lhs, rhs in
            let lhsScore = lhs.element.similarity ?? -1
            let rhsScore = rhs.element.similarity ?? -1
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return lhs.offset < rhs.offset // stable for equal/unscored hits
        }
        var seen = Set<String>()
        var lines: [String] = []
        for (_, hit) in ranked {
            let line: String
            if let heading = hit.heading, !heading.isEmpty {
                line = "— \(hit.itemTitle) §\(heading)"
            } else {
                line = "— \(hit.itemTitle)"
            }
            if seen.insert(line).inserted {
                lines.append(line)
            }
        }
        return lines
    }
}
