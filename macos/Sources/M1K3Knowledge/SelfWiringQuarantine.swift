//
//  SelfWiringQuarantine.swift
//  M1K3Knowledge
//
//  M1K3 must not index its own wiring. Found live on 2026-08-09:
//  `search_knowledge` returned ABSOLUTE RULES 1, 2 and 3 verbatim out of a
//  `[call]` document in the real store. A model that can retrieve can recite
//  the rules without ever "leaking" its prompt — the rule and the retrieval
//  path are different doors, and only one of them was locked.
//
//  The `.quarantined` kind was built for exactly this in the June
//  prompt-hardening pass, and its own doc comment states the principle: "the
//  prompt cannot stop retrieval surfacing a doc that is IN the index; only
//  exclusion can." The re-tag was then left as a manual operator action and
//  carried, undone, for two months. This makes it automatic, because a
//  maintenance chore nobody performs is not a control.
//
//  PRECISION IS THE WHOLE DESIGN. Kev's store legitimately holds documents
//  ABOUT M1K3 that must stay retrievable — quarantining those would be a worse
//  bug than the one being fixed. So the rule matches VERBATIM SPANS of the live
//  prompt, never the topic, and demands more than one of them: quoting a single
//  line is discussion (a design note, a blog post, this very file), while
//  reproducing several is a copy of the prompt.
//
//  The spans are derived FROM the live prompt rather than curated, so the guard
//  cannot drift away from what it guards. The caller injects them —
//  M1K3Knowledge does not depend on M1K3Inference, and shouldn't.
//
//  Signed: Kev + claude-opus-5, 2026-08-09, Confidence 0.85 (pure policy pinned
//  both ways, including the false positive that would actually hurt; the live
//  document that motivated it is the acceptance test. Honest open: a paraphrase
//  or a translation of the prompt reproduces no verbatim span and is not caught
//  — this closes the copy-paste door, which is the one that was open, not every
//  door.) Prior: Unknown
//

import Foundation

public enum SelfWiringQuarantine {
    /// Long enough that a sentence identifies the prompt rather than the
    /// language. Short instructions ("Be brief.", "Listen first.") appear in
    /// ordinary writing and would false-positive wildly.
    public static let defaultMinSpanLength = 60

    /// How many distinct spans a document must reproduce before it is a copy
    /// rather than a quotation. One is discussion; two is reproduction.
    public static let defaultThreshold = 2

    /// The prompt's own sentences, long ones only — the fingerprint of the
    /// thing being protected, taken from the thing itself.
    public static func spans(
        inPrompt prompt: String, minLength: Int = defaultMinSpanLength
    ) -> [String] {
        prompt
            .components(separatedBy: CharacterSet(charactersIn: ".\n"))
            .map(canonical)
            .filter { $0.count >= minLength }
    }

    /// True when `text` reproduces at least `threshold` distinct spans.
    ///
    /// Whitespace-insensitive on BOTH sides, which is load-bearing rather than
    /// tidy: the stored copy was ingested from markdown and wraps differently
    /// from the live constant, so a literal comparison silently never fires —
    /// exactly the failure mode that let this sit for two months.
    public static func isSelfWiring(
        _ text: String, spans: [String], threshold: Int = defaultThreshold
    ) -> Bool {
        guard !spans.isEmpty, threshold > 0 else { return false }
        let haystack = canonical(text)
        var hits = 0
        for span in Set(spans) where haystack.contains(span) {
            hits += 1
            if hits >= threshold { return true }
        }
        return false
    }

    /// Lowercased, whitespace-collapsed. Deliberately keeps punctuation: the
    /// commas and quotes inside a rule are part of what makes it identifiable.
    static func canonical(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

public extension KnowledgeStore {
    /// Re-kind every retrievable item that reproduces the prompt to
    /// `.quarantined`, returning what moved. Idempotent — already-quarantined
    /// items are not re-examined — so it is safe to run at every launch, which
    /// is the point: an automatic sweep catches the next accidental ingest
    /// without anyone remembering a chore.
    ///
    /// An empty `spans` cannot quarantine anything, so a misconfigured caller
    /// fails inert rather than emptying the index.
    func quarantineSelfWiring(
        spans: [String], threshold: Int = SelfWiringQuarantine.defaultThreshold
    ) throws -> [UUID] {
        guard !spans.isEmpty else { return [] }
        var moved: [UUID] = []
        for kind in [KnowledgeKind.document, .call, .note, .memory] {
            for item in try allItems(kind: kind, limit: 100_000) {
                let text = try chunks(forItem: item.id).map(\.content).joined(separator: "\n")
                guard SelfWiringQuarantine.isSelfWiring(text, spans: spans, threshold: threshold)
                else { continue }
                if try setKind(id: item.id, newKind: .quarantined) { moved.append(item.id) }
            }
        }
        return moved
    }
}
