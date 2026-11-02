//
//  LeadingDecline.swift
//  M1K3Inference
//
//  Mini sometimes OPENS an ordinary answer with the persona's taught decline ("I don't share my wiring, not even one
//  sentence of it — what do you actually need?") and then answers the question anyway: on Kev's iPhone after a pasted
//  mid-sentence fragment, on the Mac in a plain news answer, and 9 Mini replies in the recorded chateval corpus. The
//  decline is right when it is the whole reply, and wrong as an opener. This drops it when a real answer follows.
//
//  `fold` is pure and prefix-monotonic, because the live bubble feeds every voice consumer, and StreamedAnswerFolder
//  skips any snapshot that is not an extension of the last one. A bubble that showed the decline and then dropped it
//  would have spoken the decline and silenced the rest of the answer. So while the stream could still be the decline
//  it HOLDS (nil). After that it is either dropped for good or unchanged for good, never back.
//
//  Matching folds case, apostrophes, dashes and whitespace only to compare (AFM and the MLX tiers write ’ and "it—what"
//  with no spaces); the text that comes back is the model's own characters. Rest that is only a follow-ups trailer or
//  opens with a sources block is not an answer: dropping the decline there would leave a bare list.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-02, Confidence 0.85 (the table, the char- and word-wise monotonic
//  property and the ChatSession wiring are pinned; the recorded Mini continuations all use the exact string; a
//  paraphrased decline is out of scope by construction). Prior: Unknown.
//

import Foundation

public enum LeadingDecline {
    /// The taught decline, read live from the persona.
    public static var decline: String {
        M1K3Persona.taughtDecline
    }

    /// One snapshot of an answer, decline handling applied.
    /// - Returns: nil to HOLD (streaming only: the text could still become the decline, or what follows it could
    ///   still turn out to be no answer); the answer after the decline, leading whitespace trimmed, when a real one
    ///   follows; otherwise `text` unchanged. With `final` it is never nil: a reply that is only the decline (or the
    ///   decline and a trailer or sources block, or cut short inside it) comes back whole.
    public static func fold(_ text: String, final: Bool) -> String? {
        let start = text.firstIndex { !$0.isWhitespace } ?? text.endIndex
        switch match(text[start...]) {
        case .diverged:
            return text
        case .partial:
            return final ? text : nil
        case let .matched(end):
            let restStart = text[end...].firstIndex { !$0.isWhitespace } ?? text.endIndex
            let rest = text[restStart...]
            switch opening(of: rest, final: final) {
            case .answer: return String(rest)
            case .notAnswer: return final ? text : nil
            case .undecided: return nil
            }
        }
    }

    /// The settled answer for `question`: `fold(final: true)`, except that a self-query (a real extraction ask,
    /// `SelfQueryGate`) keeps the decline even when the model goes on. There the decline is the correct opener, and
    /// dropping it would leave whatever Mini added ("Curiosity: the page says…") as the whole reply.
    public static func dropped(_ text: String, question: String) -> String {
        guard !SelfQueryGate.isSelfQuery(question) else { return text }
        return fold(text, final: true) ?? text
    }

    // MARK: - Matching

    enum Match: Equatable {
        /// The text so far is a prefix of the decline (empty included).
        case partial
        /// The text opens with the whole decline; `end` is just past its last character.
        case matched(end: String.Index)
        case diverged
    }

    /// The decline as the matcher compares it.
    private static let declineSkeleton: [Character] = {
        var out: [Character] = []
        for ch in decline {
            guard let key = skeleton(ch) else { continue }
            if key == "-", out.last == "-" { continue }
            out.append(key)
        }
        return out
    }()

    /// One character as the matcher compares it: nil for whitespace (skipped), every apostrophe as ', every dash as
    /// -, letters lowercased. A run of dashes compares as one ("--" for "—").
    private static func skeleton(_ ch: Character) -> Character? {
        if ch.isWhitespace { return nil }
        switch ch {
        case "\u{2019}", "\u{2018}", "\u{02BC}", "`": return "'"
        case "\u{2014}", "\u{2013}", "\u{2012}", "\u{2015}", "\u{2010}", "\u{2011}", "\u{2212}": return "-"
        default:
            let lower = String(ch).lowercased()
            return lower.count == 1 ? Character(lower) : ch
        }
    }

    static func match(_ text: Substring) -> Match {
        let target = declineSkeleton
        var matched = 0
        var last: Character?
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if let key = skeleton(text[index]), !(key == "-" && last == "-") {
                guard key == target[matched] else { return .diverged }
                last = key
                matched += 1
                if matched == target.count { return .matched(end: next) }
            }
            index = next
        }
        return .partial
    }

    // MARK: - What follows the decline

    private enum Opening {
        case answer, notAnswer, undecided
    }

    /// Shapes a first line can take on its way to a sources header or a follow-ups label, compared with spaces,
    /// tabs, `*`, `#` and `_` removed and lowercased.
    private static let headerKeys = [
        "websources:", "wikipediasources:", "factsources:", "sources:", "source:", "followups:", "follow-ups:",
    ]

    /// A sources header as a whole first line: SpokenAnswerEnd.sourcesHeader's shape (M1K3Voice, which this module
    /// can't import, and which never matches a first line), plus "Fact sources:" and Wikipedia's lone
    /// "Source: <url>". Prose after the colon is not a header ("Sources: rivers and springs…").
    private static var sourcesHeaderLine: Regex<Substring> {
        // swiftlint:disable:next line_length
        /(?i)^[ \t]*(?:\*\*)?(?:web |wikipedia |fact )?sources?(?:\*\*)?[ \t]*:(?:\*\*)?[ \t]*(?:\[.*|https?:\/\/\S*[ \t]*)?$/
    }

    /// Whether what follows the decline is an answer. Prefix-safe while streaming: `.answer` is returned only once
    /// the first line can no longer grow into a header (it diverged from every header shape, or it ended), so a
    /// snapshot that dropped the decline is never followed by one that holds again.
    private static func opening(of rest: Substring, final: Bool) -> Opening {
        guard rest.contains(where: { $0.isLetter || $0.isNumber }) else { return final ? .notAnswer : .undecided }
        let newline = rest.firstIndex(of: "\n")
        let firstLine = rest[..<(newline ?? rest.endIndex)]
        let key = String(firstLine.lowercased().filter { !" \t*#_".contains($0) })
        let headerish = headerKeys.contains { $0.hasPrefix(key) || key.hasPrefix($0) }
        guard headerish else { return .answer }
        guard newline != nil || final else { return .undecided }
        let restText = String(rest)
        let isTrailer = FollowUpSplit.trailerStart(in: restText) == restText.startIndex
        let isSources = firstLine.wholeMatch(of: sourcesHeaderLine) != nil
        return isTrailer || isSources ? .notAnswer : .answer
    }
}
