//
//  HashingMemoryGate.swift
//  M1K3Knowledge
//
//  #447: on the hashing embedder (Mini's on the Mac, every tier's on iPhone and iPad) a memory
//  reaches the prompt only if it shares a content word with the question. A hashing cosine is
//  bucket collisions, not meaning: "tell me a joke" scored 0.387 against a Galway half marathon
//  (the memory floor is 0.10), and Mini worked that memory into 14 of 15 unrelated answers
//  whatever the memory header said (macos/docs/evals/2026-10-29-mini-memory-noise.md).
//
//  The rule is #670's keyword lane turned on memories: the question's content words
//  (`HashingKeywordLane.contentTerms`) must meet the memory's, less the distiller's register
//  word "user". No stemming (the challenger measured it as cost without benefit) and no high-
//  cosine escape (none recovered a relevant pair at any threshold). A profile ask ("What do you
//  remember about me?", a shipped door chip) keeps every memory, as today: every memory answers
//  it. Any other embedder passes through untouched.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-29
//  Context: three independent designs converged on this rule; it FAILED its pre-registered blind
//  bar (447-blind-fresh: 19/40 relevant kept vs 32/40 today, 9/25 unrelated admitted vs 21/25,
//  bar <= 10%), and Kev overrode the bar knowingly (2026-10-29): an unrelated memory in an answer
//  is visible and costs ratings, an omitted one is not. On a small store the cost is real: the
//  right memory reaches the prompt 80% -> 48% of the time, losing facts that need a leap
//  ("coeliac" for a pasta question). HashingMemoryGateTurnTests pins both sides at turn level.
//  Confidence: 0.65 — the noise fix is robust across store sizes; the recall loss is measured on
//  English fixtures only (other languages: all-or-nothing, untested). Revert = drop the one call.
//  Open: a real embedder for Mini (or a lexical memory lane) is the fix after the freeze.
//  Format: MurphySig v0.4 (https://murphysig.dev/spec). Prior: none (new file).
//

import Foundation

public enum HashingMemoryGate {
    /// The memories a hashing-arm turn may carry: those sharing a content word with the question,
    /// or all of them for a profile ask. The identity on any other embedder.
    public static func admitted(_ memories: [ChunkHit], question: String, fingerprint: String) -> [ChunkHit] {
        guard fingerprint.hasPrefix("hashing/"), !isProfileAsk(question) else { return memories }
        let asked = terms(question)
        guard !asked.isEmpty else { return [] }
        return memories.filter { !terms("\($0.itemTitle) \($0.content)").isDisjoint(with: asked) }
    }

    /// "What do you remember about me?", "who am I?": a question every memory answers.
    /// "about my sister" or "about meteors" is not one.
    public static func isProfileAsk(_ question: String) -> Bool {
        question.range(of: #"\babout (me|myself|us|ourselves)\b|\bwho am i\b"#, options: [.regularExpression, .caseInsensitive])
            != nil
    }

    /// The distiller writes "The user prefers …": its register, not a subject a question shares.
    static let registerWords: Set<String> = ["user", "users"]

    private static func terms(_ text: String) -> Set<String> {
        Set(HashingKeywordLane.contentTerms(text) ?? []).subtracting(registerWords)
    }
}
