//
//  StyleAskFence.swift
//  M1K3Chat
//
//  #699 Phase 1: a `style` fact ("The user prefers short answers.") rides every
//  system prompt once stored, so it must come from something the user ASKED for,
//  never from how they behave (terse turns are not a request for terse answers).
//  The distiller prompt says so; this is the deterministic backstop the prompt
//  cannot guarantee, the same shape as #284's attribution fence and applied after it.
//
//  One rule, fail-closed: a style fact survives only if ONE sentence of a user turn (or
//  one line of it) both anchors it (shares a content token, by DistillationAttribution's
//  own token rule) and reads as a request: a cue phrase anywhere in that sentence, or an
//  imperative lead about form. The cue must sit in the anchoring sentence, so "please
//  tell me about Cork" cannot vouch for a style fact some other turn anchors, and a
//  pasted email or article (a "please" in one line, "answers" in another) cannot vouch
//  for one either. The verb the distiller prompt mandates ("The user prefers/wants…")
//  is scaffold, not content: it never anchors, or any turn saying "my sister wants…"
//  would.
//
//  Known, accepted costs (Kev's call, named in the PR):
//  - A bare "yes" to M1K3's own "want me to be briefer?" fails, as in #284: the
//    assistant's offer is never evidence. "Shorter please" passes.
//  - A complaint with no cue ("your answers are long") fails; "too long" passes.
//  - The fence cannot tell a one-off task ask ("write me a shorter email") from a
//    standing one; the distiller prompt carries that line, and an edit or forget in
//    the Memories list undoes a wrong row.
//  - An ask split across sentences ("Too long. Shorter, please." anchors only in the
//    second, which also asks, so it passes; "Your answers. Please." does not).
//  - Kind-blind supersede: the coordinator's twin search ignores kind, so a later
//    fact filed under another kind ("The user prefers shorter answers." as a
//    preference) at or above the embedder's twin bar supersedes a live style row,
//    and the line loses that ask. Pinned in StyleMemoryScenarioTests; Kev's call.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.8 (pure and pinned in
//  StyleAskFenceTests; the cue list is a heuristic, so its width is unmeasured on
//  live conversations), Prior: none (new file)
//  Review: Kev + claude-opus-5.5, 2026-10-27 (pre-push review fold) — narrowed twice, both fail-closed: the
//  anchor and the ask must share one sentence or line (a pasted paragraph carried a cue in one line and an
//  anchor in another), and "prefers"/"wants", which the prompt puts in every style fact, no longer anchor.
//  Every cue and lead is pinned one by one. Confidence 0.8.
//

import Foundation

public enum StyleAskFence {
    /// Phrases that make a turn a request wherever they sit: word-bounded, matched on
    /// the lowercased turn with curly apostrophes straightened. One family per line;
    /// each family is pinned in StyleAskFenceTests.
    static let requestCues: [String] = [
        // Politeness and direct requests.
        "please", "can you", "could you", "would you", "will you", "can we", "could we",
        "i need you to", "i want you to",
        // Negatives.
        "don't", "dont", "do not", "stop", "no more", "quit", "enough with",
        // A stated preference.
        "i prefer", "i'd prefer", "i would prefer", "i'd rather", "i would rather",
        "i'd like", "i would like", "i like it when", "i want",
        // Standing directives.
        "keep it", "keep them", "keep your", "keep answers", "skip the", "just give", "just tell",
        "get to the point", "explain like", "talk to me like", "speak to me like",
        "from now on", "going forward", "in future", "next time",
        // A complaint about the form, or the comparative that asks for a change.
        "too long", "too short", "too much", "too many", "too wordy", "too formal", "too casual",
        "shorter", "longer", "briefer", "simpler", "fewer", "less", "more detail",
    ]

    /// A turn whose first word (after any filler) is one of these is an instruction about
    /// form: "keep it short", "skip the intro", "no lists". Task verbs ("write", "explain",
    /// "tell", "give", "make") are left out on purpose: they open most asks for CONTENT,
    /// and "write me a short poem" is not a standing ask about answers.
    static let imperativeLeads: Set<String> = [
        "be", "keep", "skip", "stop", "use", "avoid", "drop", "ditch", "lose", "cut",
        "answer", "reply", "respond", "talk", "speak", "always", "never", "no", "less", "fewer",
    ]

    /// Words passed over before the lead: "ok, skip the intro", "and keep it short".
    static let fillers: Set<String> = [
        "ok", "okay", "and", "also", "oh", "so", "right", "hey", "alright", "um",
    ]

    /// The words the distiller prompt puts in every style fact ("The user prefers…",
    /// "The user wants…"). Scaffold, not content: they never anchor.
    static let scaffoldTokens: Set<String> = ["prefers", "prefer", "wants", "want"]

    /// True when one sentence (or line) of one of `userTurns` both anchors `fact` and
    /// reads as a request. `selfNames` never count as anchoring evidence, as in `isAnchored`.
    public static func isExplicitAsk(
        fact: String,
        userTurns: [String],
        selfNames: DistillationAttribution.UserNames = .none
    ) -> Bool {
        let factTokens = DistillationAttribution.contentTokens(in: fact, selfNames: selfNames)
            .subtracting(scaffoldTokens)
        guard !factTokens.isEmpty else { return false }
        return userTurns.lazy.flatMap(segments).contains { segment in
            !factTokens.isDisjoint(with: DistillationAttribution.contentTokens(in: segment, selfNames: selfNames))
                && isRequest(segment)
        }
    }

    /// A turn's sentences and lines: split at every line break, and after a `.`, `!` or `?`
    /// that ends the text or meets whitespace (so "3.5" stays whole). Trimmed, none empty.
    static func segments(_ turn: String) -> [String] {
        var segments: [String] = []
        var current = ""
        let characters = Array(turn)
        for (index, character) in characters.enumerated() {
            if character.isNewline {
                segments.append(current)
                current = ""
                continue
            }
            current.append(character)
            let atBoundary = index + 1 == characters.count || characters[index + 1].isWhitespace
            if ".!?".contains(character), atBoundary {
                segments.append(current)
                current = ""
            }
        }
        segments.append(current)
        return segments.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Whether `turn` reads as a request: an imperative lead about form, or any cue phrase.
    static func isRequest(_ turn: String) -> Bool {
        let text = normalised(turn)
        if let lead = leadWord(text), imperativeLeads.contains(lead) { return true }
        return requestCues.contains { containsPhrase($0, in: text) }
    }

    /// Lowercased, curly apostrophes straightened (a keyboard sends "don’t"), whitespace collapsed.
    static func normalised(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// The first word after any fillers, or nil when that word carries punctuation:
    /// "no," and "right." are interjections, not instructions.
    static func leadWord(_ text: String) -> String? {
        for raw in text.split(separator: " ") {
            let word = String(raw)
            let bare = word.trimmingCharacters(in: .punctuationCharacters)
            if fillers.contains(bare) { continue }
            return bare == word ? bare : nil
        }
        return nil
    }

    private static func containsPhrase(_ phrase: String, in text: String) -> Bool {
        text.range(
            of: "\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b",
            options: .regularExpression
        ) != nil
    }
}
