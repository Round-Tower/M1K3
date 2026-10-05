//
//  SelfNoteClassifier.swift
//  M1K3Chat
//
//  #286: a visitor memory describing M1K3's OWN tooling — saved by an
//  agent over MCP `remember` — got retrieved into "WHAT I KNOW ABOUT YOU"
//  and made Lil decline innocent questions with the SELF/WIRING refusal:
//  "busiest days this week?" reads as a question about M1K3's configuration
//  once a memory has already told it that phrase describes the
//  `recent_activity` tool's own output. The memory was true and useful —
//  just not a fact ABOUT THE USER, so it never belonged in that block.
//
//  Conservative by design: a false negative (a wiring note that slips
//  through) just reverts to today's behaviour; a false positive (a genuine
//  user memory wrongly excluded) silently erases something Kev actually
//  told M1K3. So this only fires when BOTH conditions hold — M1K3 is
//  grammatically the SUBJECT, AND the text carries a concrete code/wiring
//  marker — never on subject or marker alone.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-11, Confidence 0.85 (fully pinned
//  in SelfNoteClassifierTests, incl. the live note's own text and the
//  deliberately conservative "subject with no marker" borderline case).
//  Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-09-11 (review 1 fold, pre-merge) — the title check
//  counted any MENTION of M1K3 as the subject and the markers were substrings ("committed",
//  "emerged"), so "Kev asked M1K3 to track his sleep" + "committed to bed by 11pm" was dropped
//  from WHAT I KNOW ABOUT YOU. Title and text now share one subject-shaped test; markers are
//  whole words, and scanned in the title as well as the text (a marker that lives only in
//  the title counted for nothing). Pinned by titleMentionWithoutSubjectIsNotFlagged,
//  markersAreWholeWords, markerInTitleCounts. Review 3: the bare "tool" marker is gone — it made
//  "mcp tool" dead code and flagged "M1K3 is a useful tool" (bareToolWordIsNotAMarker).
//  Review: Kev + claude-opus-5.5, 2026-10-05 — #482: both subject rules matched ANYWHERE, so Kev's
//  dev-history episodes ("On 2026-10-02 Kev and Claude made M1K3's launch film…" plus a backticked
//  render line; the 2026-09-08 hit-list day) were dropped as wiring notes, and chat answered "no
//  record" for a memory recall ranked #1 (live log: "dropped as wiring-shaped self notes: 2").
//  The title or text must now OPEN with M1K3 (after any bullet/quote). Every #286 pin holds;
//  mid-text openers ("A quiet day. M1K3's palette…") are now accepted misses — the header's
//  safe direction. Challenger-shaped: a per-opener character class was growing into a grammar.
//  Pinned by laterMentionIsNotTheSubject and openingSubjectIsStillFlagged. Confidence 0.8.
//

import Foundation

public enum SelfNoteClassifier {
    /// The assistant's own name(s) — mirrors MemoryFactValidator.assistantNames.
    private static let selfNames = ["m1k3"]

    /// Verbs/auxiliaries that, immediately after the assistant's name, mark
    /// it as the sentence's grammatical subject rather than a passing
    /// mention ("Kev's favourite app is M1K3" does NOT match this).
    private static let subjectVerbs = [
        "can", "gained", "now", "is", "has", "was", "shipped", "supports",
        "offers", "learned", "reviews", "runs", "reads",
    ]

    /// Concrete code/wiring markers — the class of evidence a genuine
    /// self-note about a tool, PR, or install carries and a lived-episode
    /// sentence about M1K3 (an interview, a compliment) does not. Whole
    /// words: "committed" and "emerged" are English, not git (review 1).
    private static let wiringPatterns = [
        "\\bpr ?#", "\\bmerged\\b", "\\bcommits?\\b", "\\binstalled\\b",
        "\\bpalette\\b", "\\bmcp tools?\\b",
        // NOT bare "tool": "M1K3 is a useful tool" is an opinion, not wiring.
    ]

    /// True only when the note is WIRING-SHAPED: M1K3 is the subject of the
    /// title or text AND at least one code/wiring marker is present. Either
    /// alone is not enough — see the file header.
    public static func isWiringNote(title: String, text: String) -> Bool {
        subjectIsSelf(title: title, text: text) && hasWiringMarker(title + " " + text)
    }

    /// The title and the text are held to the SAME subject test: each must
    /// OPEN with M1K3 — as possessor ("M1K3's palette gained…") or as the noun
    /// a subject verb follows ("M1K3 gained…"), after any leading bullet,
    /// quote or bracket. A wiring note states its topic first; a lived episode
    /// opens with its date or its people ("On 2026-10-02 Kev and Claude made
    /// M1K3's launch film…", "Kev asked why M1K3 was slow…"), so a mention
    /// later in the text is never the subject (#482). Anchoring both rules at
    /// the start replaced the anywhere-match that hid those episodes from chat.
    private static func subjectIsSelf(title: String, text: String) -> Bool {
        opensWithSelf(title) || opensWithSelf(text)
    }

    private static func opensWithSelf(_ sentence: String) -> Bool {
        let lower = sentence.lowercased()
        let verbs = subjectVerbs.joined(separator: "|")
        return selfNames.contains { name in
            let pattern = "^[\\s\\-*\u{2022}\"\u{201C}'(\\[]*\(name)(?:['\u{2019}]s\\b|\\s+(?:\(verbs))\\b)"
            return lower.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private static func hasWiringMarker(_ text: String) -> Bool {
        if text.contains("`") { return true }
        let lower = text.lowercased()
        // A snake_case( identifier — e.g. `recent_activity(window, focus)`.
        if lower.range(of: "\\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\\(", options: .regularExpression) != nil {
            return true
        }
        return wiringPatterns.contains { lower.range(of: $0, options: .regularExpression) != nil }
    }
}
