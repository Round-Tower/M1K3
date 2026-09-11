//
//  ExemplarEcho.swift
//  M1K3Eval
//
//  The parrot instrument. A small model reads the persona's voice exemplars as
//  lines to replay: the greeting beat came back verbatim in 52 of 198 live first
//  replies (chat-history.sqlite, 2026-09-11) and the harness passed it every
//  time, because nothing here could see it. This derives the exemplar REPLY
//  sentences from the live constant (so the fingerprint can never drift from the
//  thing it watches) and answers one question: does an answer reproduce one?
//
//  Sentence-level and lowercase, with the scorer's apostrophe normalisation —
//  a paraphrase is not an echo; a whole sentence is. The floor (40 chars) is
//  lower than PersonaLeakGuard's 60 on purpose: the guard replaces a live
//  answer and must be sure; this only scores.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-11, Confidence 0.85 (pure; pinned by
//  ChatEvalScorerTests against the live persona; the in-app effect is the
//  CHATEVAL column), Prior: Unknown
//

import Foundation
import M1K3Inference

public enum ExemplarEcho {
    /// A whole sentence at or above this length counts; shorter fragments are
    /// ordinary language ("Read the room.").
    public static let minSpan = 40

    /// The kinds where an echo is a FAIL — the character surfaces. Elsewhere
    /// (security, tool-use, instruction) the check is informational.
    public static let characterKinds: Set<TaskKind> = [.openChat, .humour, .interview]

    /// Exemplar reply sentences, normalised. Derived from the live constant on
    /// every read so a persona edit is reflected without a second list to keep.
    public static var spans: [String] {
        sentences(in: replyText(of: M1K3Persona.voiceExemplars))
    }

    /// The first exemplar sentence the answer reproduces, or nil.
    public static func echoedSpan(in answer: String) -> String? {
        let haystack = normalise(answer)
        return spans.first { haystack.contains($0) }
    }

    /// The exemplars with each bullet's `Asked …: ` lead-in stripped (the
    /// reply a model would replay, not the illustration framing) and the
    /// bullet dash removed.
    static func replyText(of exemplars: String) -> String {
        exemplars
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line -> String in
                var text = line.trimmingCharacters(in: .whitespaces)
                guard text.hasPrefix("- ") else { return text } // the header keeps its own line
                text.removeFirst(2)
                // Every beat is `<lead-in>: <reply>` — "Asked …: ", "A greeting (…): ",
                // "\"Long day…\": " — so the reply starts after the FIRST ": ".
                if let colon = text.range(of: ": ") {
                    return String(text[colon.upperBound...])
                }
                return text
            }
            .joined(separator: "\n")
    }

    /// Sentence split on terminal punctuation followed by a space, or a newline;
    /// keeps only spans at or above the floor, normalised.
    static func sentences(in text: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(text)
        for (index, ch) in chars.enumerated() {
            if ch == "\n" {
                out.append(current)
                current = ""
                continue
            }
            current.append(ch)
            if ".?!".contains(ch), index + 1 < chars.count, chars[index + 1] == " " {
                out.append(current)
                current = ""
            }
        }
        out.append(current)
        return out
            .map { normalise($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0.count >= minSpan }
    }

    /// Lowercase; curly quotes and apostrophes folded to their straight forms.
    static func normalise(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
    }
}
