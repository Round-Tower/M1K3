//
//  SelfNoteClassifierTests.swift
//  M1K3ChatTests
//
//  #286: a visitor memory describing M1K3's OWN tooling ("M1K3's interactive
//  chat palette gained `recent_activity(window, focus)`…") got injected into
//  "WHAT I KNOW ABOUT YOU" and tripped the SELF/WIRING decline on innocent
//  asks like "what were the busiest days this week?" — a phrase lifted from
//  the memory's own description of the tool's output. This classifier is the
//  write-shape test that keeps such notes out of the personal-facts block.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-11, Confidence 0.85 (fully pinned
//  here, including the live note's own text as a fixture and the deliberately
//  conservative borderline case; AgentRAGResponderTests pins the block-level
//  exclusion, and the blank-canvas chip filter in M1K3App is verify-by-launch
//  — that target is outside `swift test`).
//  Prior: Unknown
//

@testable import M1K3Chat
import Testing

struct SelfNoteClassifierTests {
    @Test("the live #286 witness: M1K3-subject text with backtick + PR marker is wiring-shaped")
    func liveWitnessIsWiringShaped() {
        #expect(SelfNoteClassifier.isWiringNote(
            title: "recent_activity tool shipped — M1K3 can review his own week (2026-09-11, PR #275)",
            text: "M1K3's interactive chat palette gained `recent_activity(window, focus)` on 2026-09-11 "
                + "(PR #275, merged ca81b1fb, installed on the Mac)."
        ))
    }

    @Test("Kev-subject memories are never flagged, whatever markers happen to be nearby")
    func userMemoriesAreNeverFlagged() {
        #expect(!SelfNoteClassifier.isWiringNote(
            title: "Kev prefers detailed answers",
            text: "Kev prefers detailed, verbose summaries when seeking context about recent activity."
        ))
        // Even mentioning the tool's own name and "tool" doesn't flip it —
        // the SUBJECT is the user, not M1K3.
        #expect(!SelfNoteClassifier.isWiringNote(
            title: "",
            text: #"The user has decided to ask for the "recent_activity" tool again."#
        ))
    }

    @Test("an M1K3-subject sentence with no wiring marker is NOT flagged — the conservative call")
    func selfSubjectWithoutMarkerIsNotFlagged() {
        // A lived episode, not a wiring note: M1K3 is grammatically the
        // subject, but nothing here is code/PR-shaped. Per #286's proposed
        // shape, this stays OUT of the wiring lane — losing recall on a real
        // self-note is worse than the rare over-broad block here.
        #expect(!SelfNoteClassifier.isWiringNote(
            title: "M1K3 was interviewed by a frontier model",
            text: "M1K3 was interviewed by a frontier model, fielding hard questions about privacy "
                + "and provenance with good humour."
        ))
    }

    @Test("a wiring marker alone, with no M1K3 subject, is NOT flagged")
    func markerWithoutSubjectIsNotFlagged() {
        #expect(!SelfNoteClassifier.isWiringNote(
            title: "Kev's PR habits",
            text: "Kev usually merges his own `PR #` chains late at night after a commit binge."
        ))
    }

    @Test("a title that merely MENTIONS M1K3 is not a self subject — review 1's sleep-schedule memory")
    func titleMentionWithoutSubjectIsNotFlagged() {
        // M1K3 is the OBJECT here ("asked M1K3 to…"), and "committed" is not
        // a git commit. Both factors false-fired in the first cut.
        #expect(!SelfNoteClassifier.isWiringNote(
            title: "Kev asked M1K3 to track his sleep schedule",
            text: "Kev is committed to going to bed by 11pm most nights."
        ))
    }

    @Test("wiring markers match whole words — \"committed\" and \"emerged\" are not git")
    func markersAreWholeWords() {
        #expect(!SelfNoteClassifier.isWiringNote(
            title: "M1K3 is committed to the bit",
            text: "M1K3 is committed to the bit, and a pattern emerged: he likes a pun."
        ))
        // …while the real thing still matches on the word.
        #expect(SelfNoteClassifier.isWiringNote(
            title: "M1K3 gained a tool",
            text: "M1K3 gained a tool today; the commit merged at noon."
        ))
    }

    @Test("title alone can carry the M1K3 subject even when the body doesn't repeat the name")
    func titleAloneCarriesTheSubject() {
        #expect(SelfNoteClassifier.isWiringNote(
            title: "M1K3 gained a new MCP tool",
            text: "Installed and merged today: a fresh palette entry with its own `snake_case(args)` call."
        ))
    }
}
