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
    /// sentence about M1K3 (an interview, a compliment) does not.
    private static let wiringPhrases = [
        "pr #", "merged", "commit", "installed", "palette", "mcp tool", "tool ",
    ]

    /// True only when the note is WIRING-SHAPED: M1K3 is the subject of the
    /// title or text AND at least one code/wiring marker is present. Either
    /// alone is not enough — see the file header.
    public static func isWiringNote(title: String, text: String) -> Bool {
        subjectIsSelf(title: title, text: text) && hasWiringMarker(text)
    }

    private static func subjectIsSelf(title: String, text: String) -> Bool {
        if containsWord(title.lowercased(), "m1k3") { return true }
        let lower = text.lowercased()
        for name in selfNames {
            if lower.contains("\(name)'s") || lower.contains("\(name)\u{2019}s") { return true }
            for verb in subjectVerbs {
                if lower.range(of: "\\b\(name)\\s+\(verb)\\b", options: .regularExpression) != nil {
                    return true
                }
            }
        }
        return false
    }

    private static func hasWiringMarker(_ text: String) -> Bool {
        if text.contains("`") { return true }
        // A snake_case( identifier — e.g. `recent_activity(window, focus)`.
        if text.range(of: "\\b[a-z][a-z0-9]*(?:_[a-z0-9]+)+\\(", options: .regularExpression) != nil {
            return true
        }
        let lower = text.lowercased()
        return wiringPhrases.contains { lower.contains($0) }
    }

    private static func containsWord(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: "\\b\(NSRegularExpression.escapedPattern(for: needle))\\b", options: .regularExpression) != nil
    }
}
