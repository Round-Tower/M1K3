//
//  WordErrorRate.swift
//  M1K3Eval
//
//  The speech-to-text scorer: word-level edit distance between what was read
//  aloud and what an engine heard, over normalised words. Normalising decides
//  what an "error" is, so it is pinned (WordErrorRateTests): formatting never
//  counts (case, punctuation, a fada, an apostrophe, "fifteen" vs "15",
//  "twenty-third" vs "23rd", fillers like "um"), mishearing always does. Digits
//  read one by one ("zero eight seven") become a digit string, grouped by the
//  pauses (commas) between them; a clock time reads the same spoken or as
//  digits ("half past eight" = "8:30"). A corpus rate weights by words, not clips.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-15, Confidence 0.8 (pinned; the number
//  folding covers cardinals to the millions and ordinals, not years or times).
//  Prior: Unknown.

import Foundation

public enum WordErrorRate {
    public struct Score: Sendable, Equatable, Codable {
        public let errors: Int
        public let words: Int
        public var rate: Double {
            words == 0 ? 0 : Double(errors) / Double(words)
        }

        public init(errors: Int, words: Int) {
            self.errors = errors
            self.words = words
        }
    }

    public static func score(reference: String, hypothesis: String) -> Score {
        let ref = normalise(reference), hyp = normalise(hypothesis)
        return Score(errors: editDistance(ref, hyp), words: ref.count)
    }

    public static func corpus(_ scores: [Score]) -> Score {
        Score(errors: scores.reduce(0) { $0 + $1.errors }, words: scores.reduce(0) { $0 + $1.words })
    }

    /// The words that are compared: lowercased, accent- and apostrophe-free,
    /// fillers dropped, spoken numbers folded to digits.
    static func normalise(_ text: String) -> [String] {
        let folded = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
            .lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "'", with: "")
        // Hyphens join number words ("sixty-two"): a space. Other punctuation is a pause: a boundary.
        var tokens: [String] = []
        var word = ""
        func flush() {
            if !word.isEmpty { tokens.append(word) }
            word = ""
        }
        let characters = Array(folded)
        for (index, character) in characters.enumerated() {
            if character.isLetter || character.isNumber {
                word.append(character)
            } else if character == ":", !word.isEmpty, word.allSatisfy(\.isNumber),
                      index + 1 < characters.count, characters[index + 1].isNumber
            {
                word.append(character) // a clock time ("8:30") stays one word
            } else if character == "-" || character.isWhitespace {
                flush()
            } else {
                flush()
                tokens.append(boundary)
            }
        }
        flush()
        return foldTimes(foldNumbers(tokens.filter { !fillers.contains($0) })).filter { $0 != boundary }
    }

    /// Spoken clock times as digits: "half past 8" and "8:30" both read "8:30";
    /// "quarter past 3" "3:15", "quarter to 9" "8:45", "8 oclock" and "8:00" both "8".
    private static func foldTimes(_ tokens: [String]) -> [String] {
        var out: [String] = []
        var index = 0
        func hour(at offset: Int) -> Int? {
            guard index + offset < tokens.count, let value = Int(tokens[index + offset]), (1 ... 12).contains(value)
            else { return nil }
            return value
        }
        while index < tokens.count {
            let token = tokens[index]
            let next = index + 1 < tokens.count ? tokens[index + 1] : ""
            if token == "half", next == "past", let h = hour(at: 2) {
                out.append("\(h):30"); index += 3
            } else if token == "quarter", next == "past", let h = hour(at: 2) {
                out.append("\(h):15"); index += 3
            } else if token == "quarter", next == "to", let h = hour(at: 2) {
                out.append("\(h == 1 ? 12 : h - 1):45"); index += 3
            } else if Int(token) != nil, next == "oclock" {
                out.append(token); index += 2
            } else if token.hasSuffix(":00"), let h = Int(token.dropLast(3)) {
                out.append(String(h)); index += 1
            } else {
                out.append(token); index += 1
            }
        }
        return out
    }

    private static let boundary = "|"
    private static let fillers: Set = ["um", "umm", "uh", "uhh", "er", "erm", "hmm", "mm"]

    private static let units: [String: Int] = [
        "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    private static let ordinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9,
        "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15,
        "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19, "twentieth": 20, "thirtieth": 30,
        "fortieth": 40, "fiftieth": 50, "sixtieth": 60, "seventieth": 70, "eightieth": 80, "ninetieth": 90,
    ]
    private static let scales: [String: Int] = ["thousand": 1000, "million": 1_000_000]

    /// One spoken number at a time: a run of number words becomes its digits;
    /// a run of single digits ("zero eight seven") becomes a digit string; an
    /// ordinal ends its run with a suffix ("twenty third" -> "23rd").
    private static func foldNumbers(_ tokens: [String]) -> [String] {
        var out: [String] = []
        var total = 0, current = 0
        var digits = "" // the run read digit by digit, while it stays that way
        var inRun = false, onlyDigits = true, runLength = 0

        func emit(suffix: Bool = false) {
            guard inRun else { return }
            let value = total + current
            if onlyDigits, runLength > 1 {
                out.append(digits)
            } else {
                out.append(suffix ? ordinal(value) : String(value))
            }
            total = 0; current = 0; digits = ""; inRun = false; onlyDigits = true; runLength = 0
        }
        func joins(_ value: Int) -> Bool {
            guard inRun else { return true }
            if onlyDigits, value < 10 { return true } // still reading digit by digit
            let below100 = current % 100
            if value >= 20 { return below100 == 0 } // a tens word after a hundred or a scale
            if value >= 10 { return below100 == 0 } // a teen likewise
            return below100 == 0 || (below100 >= 20 && below100 % 10 == 0) // a unit after a tens word
        }

        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if let value = units[token] ?? tens[token] {
                if !joins(value) { emit() }
                if value >= 10 { onlyDigits = false }
                if onlyDigits { digits += String(value) }
                current += value
                inRun = true; runLength += 1
            } else if token == "hundred", inRun {
                current = max(current, 1) * 100; onlyDigits = false; runLength += 1
            } else if let scale = scales[token], inRun {
                total += max(current, 1) * scale; current = 0; onlyDigits = false; runLength += 1
            } else if token == "and", inRun, current % 100 == 0, current + total > 0,
                      index + 1 < tokens.count, units[tokens[index + 1]] != nil || tens[tokens[index + 1]] != nil
            {
                // "four hundred AND sixty-two": part of the number.
            } else if let value = ordinals[token] {
                if !joins(value) { emit() }
                current += value; inRun = true; onlyDigits = false; runLength += 1
                emit(suffix: true)
            } else {
                emit()
                out.append(token)
            }
            index += 1
        }
        emit()
        return out
    }

    private static func ordinal(_ value: Int) -> String {
        let suffix = switch (value % 100, value % 10) {
        case (11 ... 13, _): "th"
        case (_, 1): "st"
        case (_, 2): "nd"
        case (_, 3): "rd"
        default: "th"
        }
        return "\(value)\(suffix)"
    }

    /// Levenshtein over words: substitutions, insertions and deletions cost one each.
    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0 ... b.count)
        for (i, wordA) in a.enumerated() {
            var row = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, wordB) in b.enumerated() {
                row[j + 1] = min(previous[j + 1] + 1, row[j] + 1, previous[j] + (wordA == wordB ? 0 : 1))
            }
            previous = row
        }
        return previous[b.count]
    }
}
