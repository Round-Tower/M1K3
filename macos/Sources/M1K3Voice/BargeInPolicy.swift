//
//  BargeInPolicy.swift
//  M1K3Voice
//
//  Spoken barge-in (#640): is a partial heard WHILE M1K3 speaks the user cutting in?
//  Only with Mac voice processing live (`echoCancellationLive`): without it the mic
//  hears M1K3's own voice (21/21 words in the 2026-10-17 probe, 0/21 under VPIO).
//  Even under VPIO a little echo can leak, so a partial made mostly of the words being
//  spoken is never a barge-in, and one stray word is noise unless it is a stop word.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-25, Confidence 0.6 (the rule is pinned; the
//  thresholds are judgment until a live session under VPIO measures leak and misfires).
//  Prior: none (new file).
//

import Foundation

public enum BargeInPolicy {
    /// One word is enough when it is one of these.
    public static let stopWords: Set<String> = ["stop", "wait", "pause", "hold", "quiet", "enough", "cancel", "shush"]

    /// Words a partial needs before it counts, stop words aside.
    public static let minimumWords = 2

    /// At or above this share of the partial's words found in the answer, it is echo.
    public static let echoShare = 0.6

    /// The user's OWN words decide: those not in the answer. Two of them, or one stop
    /// word, is the user however much echo came before ("…under load, hang on, wait").
    /// A short partial with few own words ("hang on": `on` is in the answer) still
    /// counts while most of it is not the answer. A lone stop word always counts. When
    /// the answer has figures, number words are never own words: the recogniser spells
    /// "2026" as "twenty twenty six".
    public static func isBargeIn(partial: String, speaking answer: String, echoCancellationLive: Bool) -> Bool {
        guard echoCancellationLive else { return false }
        let heard = words(in: partial)
        guard !heard.isEmpty else { return false }
        if heard.count == 1, stopWords.contains(heard[0]) { return true }
        let spokenWords = words(in: answer)
        let spoken = Set(spokenWords)
        let answerHasFigures = spokenWords.contains { $0.contains(where: \.isNumber) }
        let own = heard.filter { !spoken.contains($0) && !(answerHasFigures && numberWords.contains($0)) }
        if own.count >= minimumWords || own.contains(where: stopWords.contains) { return true }
        let echoed = heard.count - own.count
        return heard.count >= minimumWords && Double(echoed) / Double(heard.count) < echoShare
    }

    /// Runs of answer words at least this long, at either end of what was heard, are
    /// echo. Shorter runs stay: a user's "no wait" or "is it safe" shares words with
    /// most answers, and a dropped first word changes the question.
    public static let echoRun = 3

    /// What the user said, without M1K3's echo around it: a leading and a trailing run
    /// of `echoRun`+ words that appear in that order in the answer are dropped. Words are
    /// compared normalised, so a final's capitals and punctuation still match the echo;
    /// the words kept are the recogniser's own. Stateless, so a rewritten partial is
    /// judged afresh.
    public static func userUtterance(_ text: String, speaking answer: String) -> String {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let keys = tokens.map { words(in: $0).joined() }
        let spoken = words(in: answer)
        guard tokens.count >= echoRun, !spoken.isEmpty else { return text }
        func isEcho(_ range: Range<Int>) -> Bool {
            let run = keys[range].filter { !$0.isEmpty }
            return run.count >= echoRun && appears(run, in: spoken)
        }
        var start = 0
        for end in stride(from: tokens.count, through: echoRun, by: -1) where isEcho(0 ..< end) {
            start = end
            break
        }
        var stop = tokens.count
        if start < tokens.count {
            for begin in start ..< tokens.count where isEcho(begin ..< tokens.count) {
                stop = begin
                break
            }
        }
        return tokens[start ..< stop].joined(separator: " ")
    }

    /// `run` occurs as a contiguous slice of `words`.
    private static func appears(_ run: [String], in words: [String]) -> Bool {
        guard run.count <= words.count else { return false }
        return (0 ... words.count - run.count).contains { Array(words[$0 ..< $0 + run.count]) == run }
    }

    /// How a recogniser spells figures out loud.
    static let numberWords: Set<String> = [
        "zero", "oh", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
        "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
        "hundred", "thousand", "million", "billion", "point", "percent", "and", "first", "second", "third",
    ]

    /// Lowercased runs of letters and digits ("Stop." → "stop").
    static func words(in text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}
