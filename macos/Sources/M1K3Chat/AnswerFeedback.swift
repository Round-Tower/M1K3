//
//  AnswerFeedback.swift
//  M1K3Chat
//
//  Per-answer feedback — one bit (good/bad) plus an optional comment — captured
//  at the moment Kev has the judgement, so M1K3's mistakes become a curated
//  corpus to tune prompts, tool-calling, and models against. The motivating
//  case: an answer that should have web-searched and didn't; the record carries
//  the question, the answer, the tools that DID fire (empty is the tell), and
//  the brain, so the row is a self-contained eval fixture / training example
//  even if the conversation is later deleted.
//
//  This is the turn-level feature docs/CONVERSATION_RATING_DESIGN.md deferred.
//  Its load-bearing privacy lines carry over: feedback is LOCAL, never enters
//  the corpus/memory graph (a rating is metadata about an answer, not a fact
//  about Kev — the distiller must never see it), never syncs, and is never
//  writable over MCP (a visiting agent cannot rate Kev's conversations).
//
//  Signed: Kev + claude-fable-5, 2026-08-19, Confidence 0.9 (pure types +
//  export TDD'd; the store/UI wiring is verify-by-launch). Prior:
//  docs/CONVERSATION_RATING_DESIGN.md (conversation-level concept).
//

import Foundation

/// One bit of judgement on an answer. Raw values match the design doc's
/// `+1`/`-1` so the column reads the same as the (unbuilt) conversation rating.
public enum FeedbackVerdict: Int, Sendable, Equatable, Codable {
    case bad = -1
    case good = 1
}

/// A captured judgement on one assistant answer. Self-contained: it holds the
/// Q/A/tools/brain context at rate-time so it survives the conversation's
/// deletion and exports without re-reading the transcript.
public struct AnswerFeedback: Sendable, Equatable, Identifiable {
    /// The rated assistant message's id — the primary key (one verdict per
    /// answer; re-rating replaces).
    public let messageID: UUID
    public let conversationID: UUID
    public let verdict: FeedbackVerdict
    /// Kev's note on WHY — the signal that makes a bad row actionable
    /// ("should have searched the web"). Optional; a thumbs-up needs none.
    public let comment: String?
    /// The paired user question, captured at rate-time.
    public let question: String
    /// The answer as rated.
    public let answer: String
    /// The tools that fired for this answer — an EMPTY list on a bad answer is
    /// often the whole story (no web_search when one was needed).
    public let toolsUsed: [String]
    /// The brain that was resident when rated (best-effort provenance —
    /// ChatMessage carries no per-turn brain today).
    public let brain: String
    public let createdAt: Date

    public var id: UUID {
        messageID
    }

    public init(
        messageID: UUID,
        conversationID: UUID,
        verdict: FeedbackVerdict,
        comment: String?,
        question: String,
        answer: String,
        toolsUsed: [String],
        brain: String,
        createdAt: Date
    ) {
        self.messageID = messageID
        self.conversationID = conversationID
        self.verdict = verdict
        // Normalise an empty/blank comment to nil so "" and "no note" are one
        // state (the UI can send either).
        let trimmed = comment?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.comment = (trimmed?.isEmpty ?? true) ? nil : trimmed
        self.question = question
        self.answer = answer
        self.toolsUsed = toolsUsed
        self.brain = brain
        self.createdAt = createdAt
    }
}

/// Pure export to JSONL — the shape mirrors the eval fixtures so a bad row
/// folds into `ChatEvalStage` and a good row seeds knows-me positives. Sources
/// are NOT included (the design doc's line: training data must not become a
/// side-channel copy of the third-party corpus); only the answer text, which
/// M1K3 authored, and the tools, which are names.
public enum AnswerFeedbackExport {
    /// One JSON object per line. `.sortedKeys` gives deterministic key order
    /// (so a diff of two exports is legible); the ISO formatter is injected for
    /// testability.
    public static func jsonl(_ rows: [AnswerFeedback], iso: (Date) -> String) -> String {
        rows.map { row in
            var object: [String: Any] = [
                "message_id": row.messageID.uuidString,
                "conversation_id": row.conversationID.uuidString,
                "verdict": row.verdict == .good ? "good" : "bad",
                "rated_at": iso(row.createdAt),
                "brain": row.brain,
                "question": row.question,
                "answer": row.answer,
                "tools_used": row.toolsUsed,
            ]
            if let comment = row.comment { object["comment"] = comment }
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                  let line = String(data: data, encoding: .utf8)
            else { return "" }
            return line
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }
}
