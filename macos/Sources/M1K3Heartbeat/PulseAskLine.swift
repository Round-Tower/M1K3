//
//  PulseAskLine.swift
//  M1K3Heartbeat
//
//  The pulse's second write (the first is TodoProposalLine's one `TODO:`): the
//  narrative may END with up to two `ASK: <question>` lines, and those become
//  the "ask me" chips on the next blank canvas. The point is WHEN the inference
//  is paid for — the heartbeat already renders in the background, so the chip
//  the user sees at 9 am was written at 3 am and the canvas reads a column.
//
//  Two pure halves:
//
//  - `extract` lifts the trailing ASK lines out before NarrativeGuard sees the
//    text (the guard would count them against length, and a chip's wording is
//    not the narrative's). Only the TAIL is read, the TodoProposalLine stance:
//    a model that scatters ASKs through its prose gets none of them. The
//    composer lifts `TODO:` FIRST (it reads only the last line), then the ASKs
//    off what is left — so the prompt asks for ASKs above the TODO.
//
//  - `admit` is the tripwire between what the model wrote and what is stored.
//    ★ A chip, tapped, is sent as THE USER'S OWN WORDS. The digest the model
//    wrote it from carries untrusted text (visitor names, chat titles), so a
//    chip is a laundering route the narrative is not: refuse, never repair.
//    A refusal costs one chip (the canvas falls back to the fixed sentence);
//    a false pass would put someone else's sentence in the user's mouth.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-18, Confidence 0.8 (pinned
//  red-first in PulseAskLineTests; the refusal list is what I could predict —
//  what a real brain actually writes after `ASK:` is verify-by-run).
//  Prior: none (new file).
//

import Foundation

public enum PulseAskLine {
    /// A chip has to fit the canvas. StarterPrompts holds the real cap
    /// (`maxChipLength`, 44) and is the final judge — it drops anything longer —
    /// so this number drifting is a lost chip, never a broken layout. The
    /// modules deliberately do not import each other.
    public static let maxLength = 44

    /// Two is what the canvas can use: `.pulse` chips rotate between them.
    public static let maxAsks = 2

    // MARK: - extract

    /// Lift the trailing `ASK:` lines out of a narrative. Reads upward from the
    /// end and stops at the first line that is not an ASK (blank lines between
    /// them are skipped); every ASK line read is removed from the narrative,
    /// and the `maxAsks` nearest the end are returned in the order written.
    public static func extract(from narrative: String) -> (narrative: String, asks: [String]) {
        var lines = narrative.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var found: [String] = []
        var sawAskLine = false
        while let last = lines.last {
            let bare = last.trimmingCharacters(in: .whitespaces)
            if bare.isEmpty {
                lines.removeLast()
                continue
            }
            let stripped = bare.trimmingCharacters(in: CharacterSet(charactersIn: "-*• "))
            guard stripped.lowercased().hasPrefix("ask:") else { break }
            lines.removeLast()
            sawAskLine = true
            let question = stripped.dropFirst("ask:".count).trimmingCharacters(in: .whitespaces)
            if !question.isEmpty { found.append(question) }
        }
        // No ASK line at the tail: hand the text back byte-for-byte (the blank
        // lines popped above were only ever a lookahead).
        guard sawAskLine else { return (narrative, []) }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // `found` was read bottom-up: the first `maxAsks` are the nearest the end.
        return (body, Array(found.prefix(maxAsks).reversed()))
    }

    // MARK: - admit

    /// The chip as it may be stored, or nil. Whitespace is folded to one line
    /// first; nothing else is ever rewritten — a chip is refused, not repaired.
    public static func admit(_ ask: String, digest: String, earlierDigests: [String] = []) -> String? {
        let folded = ask.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !folded.isEmpty, folded.count <= maxLength, folded.hasSuffix("?") else { return nil }
        let lowered = folded.lowercased()
        guard !forbiddenFragments.contains(where: lowered.contains) else { return nil }
        guard !instructionOpeners.contains(where: lowered.hasPrefix) else { return nil }
        // NarrativeGuard's own rule, held to the same evidence: a number in a
        // chip must already be a number in a code-composed digest.
        var allowed = NarrativeGuard.digitRuns(in: digest)
        for earlier in earlierDigests {
            allowed.formUnion(NarrativeGuard.digitRuns(in: earlier))
        }
        guard NarrativeGuard.digitRuns(in: folded).isSubset(of: allowed) else { return nil }
        return folded
    }

    /// Admit a pulse's asks in order: refusals and case-insensitive repeats
    /// drop out, and the result stops at `maxAsks`.
    public static func admitAll(_ asks: [String], digest: String, earlierDigests: [String] = []) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for ask in asks {
            guard out.count < maxAsks,
                  let chip = admit(ask, digest: digest, earlierDigests: earlierDigests),
                  seen.insert(chip.lowercased()).inserted
            else { continue }
            out.append(chip)
        }
        return out
    }

    // MARK: - The refusal lists

    /// Anything that reads as a link, markup, a code fence or a chat-template
    /// token. Substrings on purpose: there is no honest chip with a backtick.
    private static let forbiddenFragments = [
        "http:", "https:", "www.", "://",
        "`", "<", ">", "[", "]", "{", "}", "|", "\\",
        "system prompt", "instructions",
    ]

    /// An instruction wearing a question mark.
    private static let instructionOpeners = ["ignore ", "disregard ", "reveal ", "pretend ", "forget ", "you are ", "act as "]
}
