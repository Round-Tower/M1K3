//
//  NumberSpeller.swift
//  M1K3Kokoro
//
//  Digit strings → en-GB number words for the Kokoro G2P fallback chain. The
//  bundled pronunciation dictionary has no digit keys, so "15" used to be
//  silently unspoken; this maps it onto words the dictionary is guaranteed to
//  contain (the closed vocabulary is test-pinned and was probed against the
//  real 234k-entry resource).
//
//  Year-shaped numbers (1100–2099) read as spoken pairs ("twenty twenty-six"),
//  because years dominate assistant speech; "1984 units" misreading as a year
//  is the accepted trade-off.
//
//  Signed: Kev + claude-fable-5, 2026-06-11, Confidence 0.9 (pure, every rule
//  test-pinned; the year heuristic is a taste call). Prior: Unknown.
//
//  Review: Kev + claude-opus-5.5, 2026-11-15 (#838) — the year reading is now a choice
//  (`yearReading:`), so the walker can read "1500 people" as a count from the next word
//  (`SpokenNumbers.readsAsYear`); amounts, ordinals and versions never take it. More than
//  twelve digits read in groups of three with a "," pause between them, not as one long
//  string. Confidence 0.85.
//

import Foundation

public enum NumberSpeller {
    /// English (en-GB, with "and") words for an unsigned digit-string integer.
    /// Years 1100–2099 read as pairs unless `yearReading` is off; more than 12 digits
    /// read digit by digit in groups of three, a "," (a pause token) between groups.
    public static func integerWords(_ digits: Substring, yearReading: Bool = true) -> [String] {
        guard !digits.isEmpty, digits.allSatisfy(\.isASCIIDigit) else { return [] }
        guard let value = UInt64(digits), digits.count <= 12 else {
            return groupedDigitWords(digits)
        }
        if yearReading, let year = yearWords(value) { return year }
        return spell(value)
    }

    /// "1234567" → one two three , four five six , seven.
    private static func groupedDigitWords(_ digits: Substring) -> [String] {
        var words: [String] = []
        for (index, char) in digits.enumerated() {
            if index > 0, index % 3 == 0 { words.append(",") }
            if let word = digitWord(char) { words.append(word) }
        }
        return words
    }

    /// "12.5" → ["twelve","point","five"]; "1,000" → ["one","thousand"];
    /// nil if the literal is not a plain number.
    public static func numberWords(_ literal: String, yearReading: Bool = true) -> [String]? {
        let cleaned = literal.replacingOccurrences(of: ",", with: "")
        guard !cleaned.isEmpty else { return nil }
        let parts = cleaned.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }) else { return nil }
        switch parts.count {
        case 1:
            return integerWords(parts[0], yearReading: yearReading)
        case 2:
            // Fraction digits are spoken individually: 0.25 → point two five.
            let fraction = parts[1].compactMap { digitWord($0) }
            return integerWords(parts[0], yearReading: false) + ["point"] + fraction
        default:
            return nil // 1.2.3 is a version string, not a number
        }
    }

    public static func digitWord(_ char: Character) -> String? {
        guard let value = char.wholeNumberValue, (0 ... 9).contains(value), char.isASCII else { return nil }
        return units[value]
    }

    // MARK: - Spelling

    private static let units = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
        "seventeen", "eighteen", "nineteen",
    ]
    private static let tens = [
        "", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
    ]

    /// Years 1100–2099 read as two pairs ("nineteen eighty-four"), except round
    /// hundreds ("nineteen hundred") and round thousands ("two thousand").
    private static func yearWords(_ value: UInt64) -> [String]? {
        guard (1100 ... 2099).contains(value) else { return nil }
        if value % 1000 == 0 { return nil } // 2000 → "two thousand" via spell()
        if value % 100 == 0 { return spell(value / 100) + ["hundred"] }
        let high = value / 100
        let low = value % 100
        let lowWords = low < 10 ? ["oh", units[Int(low)]] : spell(low)
        return spell(high) + lowWords
    }

    private static func spell(_ value: UInt64) -> [String] {
        if value < 20 { return [units[Int(value)]] }
        if value < 100 {
            let ten = tens[Int(value / 10)]
            let unit = value % 10
            return unit == 0 ? [ten] : [ten, units[Int(unit)]]
        }
        if value < 1000 {
            let head = [units[Int(value / 100)], "hundred"]
            let rest = value % 100
            return rest == 0 ? head : head + ["and"] + spell(rest)
        }
        for (scale, word) in [(1_000_000_000 as UInt64, "billion"), (1_000_000, "million"), (1000, "thousand")]
            where value >= scale
        {
            let head = spell(value / scale) + [word]
            let rest = value % scale
            if rest == 0 { return head }
            // GB inserts "and" when what remains is small: "one million and one".
            return rest < 100 ? head + ["and"] + spell(rest) : head + spell(rest)
        }
        return [] // unreachable: all magnitudes covered above
    }
}

extension Character {
    /// Shared with KokoroG2P's run scanner — non-ASCII digits stay out of runs.
    var isASCIIDigit: Bool {
        isASCII && isNumber
    }
}
