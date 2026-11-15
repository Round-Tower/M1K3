//
//  SpokenNumbers.swift
//  M1K3Kokoro
//
//  #838: written forms → the words people say. Ordinals ("3rd" → third), currency
//  ("£5" → five pounds), colons ("10:30" → ten thirty, "John 3:16" → three sixteen),
//  fractions ("3/4" → three quarters), versions ("v1.2.3" → version one point two point
//  three), Roman numerals after a cue ("Henry VIII" → the eighth, "Psalm XXIII" →
//  twenty-three), Euclid references ("Elements I.47"), and the year-or-count call that
//  needs the neighbouring words. Pure and dictionary-free: `KokoroG2P`'s run walker
//  decides WHERE a rule applies (it keeps the written text in the caption, one word per
//  expansion: the karaoke contract) and this decides WHAT is said. Every word emitted
//  is probed against the shipped dictionary by `SpokenNumbersTests.vocabularyResolves`;
//  "sevenths" is the one plural missing, so a plural seventh says "over seven".
//
//  Signed: Kev + claude-opus-5.5, 2026-11-15, Confidence 0.8 (every rule test-pinned
//  against the real dictionary; the year-or-count and Roman cue lists are taste calls,
//  measured by ear only once the round trip runs). Prior: none (new file).
//  Format: MurphySig v0.4 (https://murphysig.dev/spec)
//  Context: Kev hears Kokoro get longer numbers and complex words wrong (#838).
//

import Foundation

public enum SpokenNumbers {
    // MARK: - Ordinals

    /// "3rd" → ["third"], "21st" → ["twenty", "first"]. Digits plus st/nd/rd/th in any
    /// case; never a year ("1500th" is a count).
    public static func ordinal(_ text: String) -> [String]? {
        let lowered = text.lowercased()
        guard lowered.count > 2,
              ["st", "nd", "rd", "th"].contains(String(lowered.suffix(2))) else { return nil }
        let digits = lowered.dropLast(2)
        guard digits.allSatisfy(\.isASCIIDigit), digits.count <= 12 else { return nil }
        let cardinal = NumberSpeller.integerWords(digits, yearReading: false)
        return ordinalized(cardinal)
    }

    /// The last cardinal word made ordinal: one → first, twenty → twentieth.
    static func ordinalized(_ cardinal: [String]) -> [String]? {
        guard let last = cardinal.last else { return nil }
        let irregular = ["one": "first", "two": "second", "three": "third", "five": "fifth",
                         "eight": "eighth", "nine": "ninth", "twelve": "twelfth"]
        let ordinalWord: String
        if let word = irregular[last] {
            ordinalWord = word
        } else if last.hasSuffix("y") {
            ordinalWord = String(last.dropLast()) + "ieth"
        } else {
            ordinalWord = last + "th"
        }
        return cardinal.dropLast() + [ordinalWord]
    }

    // MARK: - Currency

    public struct Money: Equatable, Sendable {
        /// The number words, without the unit.
        public let amount: [String]
        /// Where the unit goes: after the amount, or after a following scale word.
        public let unit: [String]
        /// The minor part spoken after the unit ("three euros FIFTY").
        public let tail: [String]
        public var all: [String] {
            amount + unit + tail
        }
    }

    private struct CurrencyNames {
        let one: String, many: String, minorOne: String, minorMany: String
    }

    private static let units: [Character: CurrencyNames] = [
        "£": CurrencyNames(one: "pound", many: "pounds", minorOne: "penny", minorMany: "pence"),
        "$": CurrencyNames(one: "dollar", many: "dollars", minorOne: "cent", minorMany: "cents"),
        "€": CurrencyNames(one: "euro", many: "euros", minorOne: "cent", minorMany: "cents"),
    ]

    public static func isCurrencySymbol(_ char: Character) -> Bool {
        units[char] != nil
    }

    /// "£5" → five pounds; "€3.50" → three euros fifty; "$0.99" → ninety-nine cents.
    /// Exactly two decimals are a minor unit; any other decimal reads as a number.
    /// `scaled`: a scale word follows ("£1 million", "$2.50 billion"), so the amount reads
    /// as a plain number and the unit is always plural: "one million pounds".
    public static func currency(symbol: Character, literal: String, scaled: Bool = false) -> Money? {
        guard let unit = units[symbol] else { return nil }
        let cleaned = literal.replacingOccurrences(of: ",", with: "")
        let parts = cleaned.split(separator: ".", omittingEmptySubsequences: false)
        guard (1 ... 2).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }) else { return nil }
        if scaled {
            guard let words = NumberSpeller.numberWords(cleaned, yearReading: false) else { return nil }
            return Money(amount: words, unit: [unit.many], tail: [])
        }
        if parts.count == 2, parts[1].count == 2, let major = UInt64(parts[0]), let minor = UInt64(parts[1]) {
            let minorWords = NumberSpeller.integerWords(Substring(String(minor)), yearReading: false)
            if major == 0 {
                return Money(amount: minorWords, unit: [minor == 1 ? unit.minorOne : unit.minorMany], tail: [])
            }
            let majorWords = NumberSpeller.integerWords(parts[0], yearReading: false)
            return Money(amount: majorWords, unit: [major == 1 ? unit.one : unit.many],
                         tail: minor == 0 ? [] : minorWords)
        }
        guard let words = NumberSpeller.numberWords(cleaned, yearReading: false) else { return nil }
        let one = parts.count == 1 && UInt64(parts[0]) == 1
        return Money(amount: words, unit: [one ? unit.one : unit.many], tail: [])
    }

    private static let scaleWords: Set = ["thousand", "million", "billion", "trillion"]

    /// "£5 million": the unit waits for the scale word ("five million pounds").
    public static func isScaleWord(_ word: String) -> Bool {
        scaleWords.contains(word.lowercased())
    }

    // MARK: - Colons, fractions, ranges

    /// "10:30" → ten thirty; "10:05" → ten oh five; "10:00" → ten o'clock (a clock-sized
    /// hour only); "3:16" → three sixteen. One colon, digits both sides.
    public static func colon(_ text: String) -> [String]? {
        var body = Substring(text)
        var meridiem: [String] = []
        switch body.suffix(2).lowercased() {
        case "am": meridiem = ["aye", "em"]
        case "pm": meridiem = ["pee", "em"]
        default: break
        }
        if !meridiem.isEmpty { body = body.dropLast(2) }
        guard let words = clock(body) else { return nil }
        if meridiem.isEmpty { return words }
        // "10:00am" is "ten a m", not "ten o'clock a m".
        return (words.last == "o'clock" ? Array(words.dropLast()) : words) + meridiem
    }

    private static func clock(_ text: Substring) -> [String]? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }),
              let left = UInt64(parts[0]), let right = UInt64(parts[1]) else { return nil }
        let hour = NumberSpeller.integerWords(parts[0], yearReading: false)
        let clockHour = parts[0].count <= 2 && left <= 24
        if parts[1].count == 2, clockHour {
            if right == 0 { return hour + ["o'clock"] }
            if right < 10 { return hour + ["oh", NumberSpeller.digitWord(parts[1].last!)!] }
        }
        return hour + NumberSpeller.integerWords(Substring(String(right)), yearReading: false)
    }

    private static let denominators: [UInt64: (one: String, many: String?)] = [
        2: ("half", "halves"), 3: ("third", "thirds"), 4: ("quarter", "quarters"),
        5: ("fifth", "fifths"), 6: ("sixth", "sixths"), 7: ("seventh", nil),
        8: ("eighth", "eighths"), 9: ("ninth", "ninths"), 10: ("tenth", "tenths"),
    ]

    /// "1/2" → a half; "1/8" → an eighth; "3/4" → three quarters; "5/16" → five over
    /// sixteen; "24/7" → twenty-four seven. A score or rating reads "out of": the top is at
    /// least the bottom ("10/10"), the bottom is 5, 10 or 100 ("7/10", "4/5"), or the top
    /// is a decimal ("4.5/5"). One slash, digits on the right.
    public static func fraction(_ text: String) -> [String]? {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].isEmpty, parts[1].allSatisfy(\.isASCIIDigit),
              let bottom = UInt64(parts[1]),
              let topWords = NumberSpeller.numberWords(String(parts[0]), yearReading: false) else { return nil }
        let bottomWords = NumberSpeller.integerWords(parts[1], yearReading: false)
        guard let top = UInt64(parts[0]) else { return topWords + ["out", "of"] + bottomWords } // "4.5/5"
        if top == 24, bottom == 7 { return topWords + bottomWords }
        if top == 1, let name = denominators[bottom] {
            return [name.one.first.map { "aeiou".contains($0) } == true ? "an" : "a", name.one]
        }
        if bottom > 0, top >= bottom || [5, 10, 100].contains(bottom) {
            return topWords + ["out", "of"] + bottomWords
        }
        if let name = denominators[bottom], top < 100, let many = name.many { return topWords + [many] }
        return topWords + ["over"] + bottomWords
    }

    /// The word between two numbers joined by a dash: "4-7", "1990–2000".
    public static let rangeWord = "to"

    // MARK: - Versions

    /// "v1.2.3" → version one point two point three; "1.2.3" (two or more dots) →
    /// one point two point three. A lowercase v only; "2.5" stays a decimal.
    public static func version(_ text: String) -> [String]? {
        var body = Substring(text)
        var prefix: [String] = []
        if body.first == "v" {
            body = body.dropFirst()
            prefix = ["version"]
        }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) }) else { return nil }
        // A bare triple needs short parts: "15.11.2026" is a date, "192.168.1.1" an address.
        guard !prefix.isEmpty || (parts.count >= 3 && parts.allSatisfy { $0.count <= 2 }) else { return nil }
        var words = prefix
        for (index, part) in parts.enumerated() {
            if index > 0 { words.append("point") }
            words += NumberSpeller.integerWords(part, yearReading: false)
        }
        return words
    }

    // MARK: - Roman numerals

    /// The value of a canonical uppercase Roman numeral (1…3999), else nil.
    private static let romanDigits: [Character: Int] = ["I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000]

    public static func romanValue(_ text: String) -> Int? {
        let values = romanDigits
        guard !text.isEmpty, text.allSatisfy({ values[$0] != nil }) else { return nil }
        let digits = text.map { values[$0]! }
        var total = 0
        for (index, value) in digits.enumerated() {
            if index + 1 < digits.count, value < digits[index + 1] { total -= value } else { total += value }
        }
        guard (1 ... 3999).contains(total), romanString(total) == text else { return nil }
        return total
    }

    private static func romanString(_ value: Int) -> String {
        let table: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
                                      (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var rest = value
        var out = ""
        for (amount, glyphs) in table {
            while rest >= amount {
                out += glyphs
                rest -= amount
            }
        }
        return out
    }

    /// Words that put a cardinal numeral after them: "Psalm XXIII", "Book IV", "World War II".
    private static let cardinalCues: Set = [
        "psalm", "psalms", "book", "chapter", "part", "volume", "vol", "act", "scene", "section",
        "article", "appendix", "phase", "war", "canto", "stage", "bowl", "episode", "season",
        "table", "plate", "tome", "class", "level", "tier", "grade",
    ]

    /// Names that take a regnal ordinal: "Henry VIII" → Henry the eighth.
    private static let regnalNames: Set = [
        "henry", "edward", "george", "william", "elizabeth", "charles", "james", "richard", "louis",
        "mary", "anne", "victoria", "peter", "catherine", "philip", "frederick", "alexander",
        "nicholas", "pius", "leo", "gregory", "benedict", "paul", "innocent", "clement", "john",
        "urban", "boniface", "ramesses", "ramses", "napoleon", "constantine", "ivan", "gustav",
        "gustavus", "christian", "olaf", "harald", "haakon", "carl", "ludwig", "wilhelm", "otto",
        "francis", "ferdinand", "isabella", "juan", "alfonso", "pedro", "joseph", "leopold",
        "rudolf", "david", "robert", "kenneth", "duncan", "harold", "stephen", "matilda",
    ]

    /// A Roman numeral read only after a cue: a regnal name → "the eighth", a cardinal
    /// cue → "twenty-three", "Elements" → "book one". No cue, no reading: the pronoun
    /// "I", "CD", "Vitamin D" stay as written. A lone C, D, L or M is a label ("Appendix C").
    /// A lone "I" is the pronoun far more often ("the book I read", "Thanks John I will"),
    /// so it needs a capitalised cue AND no lowercase word after it but "of" ("Henry I.",
    /// "Part I of"). A lone X after a cardinal cue is a placeholder ("Section X"); a lone V
    /// or X before "." and a capitalised word is a middle initial ("Charles V. Smith"); a
    /// regnal number stays under 40 ("Robert MD" is not Robert the fifteen-hundredth).
    public static func roman(_ text: String, previous: String?, next: String? = nil,
                             followedByInitialStop: Bool = false) -> [String]?
    {
        guard let previous, let first = text.first, "IVXLCDM".contains(first),
              let value = romanValue(text) else { return nil }
        if text.count == 1, !"IVX".contains(text) { return nil }
        if text.count == 1, followedByInitialStop { return nil }
        if text == "I" {
            guard previous.first?.isUppercase == true else { return nil }
            if let next, next.first?.isLowercase == true, next.lowercased() != "of" { return nil }
        }
        let cue = previous.lowercased()
        let cardinal = NumberSpeller.integerWords(Substring(String(value)), yearReading: false)
        if cue == "elements" { return ["book"] + cardinal }
        if regnalNames.contains(cue) {
            guard value < 40 else { return nil }
            return ["the"] + (ordinalized(cardinal) ?? cardinal)
        }
        if cardinalCues.contains(cue), text != "X" { return cardinal }
        return nil
    }

    /// Euclid's "Elements I.47" → book one, proposition forty-seven (the comma is a pause).
    public static func euclid(book: String, proposition: String) -> [String]? {
        guard let value = romanValue(book), !proposition.isEmpty,
              proposition.allSatisfy(\.isASCIIDigit) else { return nil }
        let bookWords = NumberSpeller.integerWords(Substring(String(value)), yearReading: false)
        return ["book"] + bookWords + [",", "proposition"]
            + NumberSpeller.integerWords(Substring(proposition), yearReading: false)
    }

    // MARK: - Year or count

    private static let months: Set = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september",
        "october", "november", "december", "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep",
        "sept", "oct", "nov", "dec",
    ]
    private static let yearCues: Set = ["year", "circa", "c", "ca"]
    private static let eras: Set = ["bc", "ad", "bce", "ce"]
    /// Words that follow a year more often than a count ("in 1984 the…", "1984 was…").
    private static let functionWords: Set = [
        "and", "or", "but", "to", "was", "is", "were", "are", "when", "the", "a", "an", "in", "on",
        "at", "for", "with", "that", "which", "as", "so", "it", "he", "she", "they", "we", "i",
        "you", "had", "has", "have", "saw", "until", "till", "by", "from", "of", "after", "before",
        "during", "while", "where", "who", "then", "onwards", "onward", "if", "be", "been", "will",
        "would", "could", "this", "these", "those", "his", "her", "its", "their", "our", "my",
    ]

    /// Words before a number that make it a year ("in 1984", "since 2019").
    private static let yearPrepositions: Set = [
        "in", "since", "by", "until", "till", "from", "during", "before", "after", "around", "circa",
    ]

    /// Whether a year-shaped number (1100–2099) reads as a year. A year when an era follows
    /// or a month, year cue or year preposition leads. Otherwise only a plausible year (up
    /// to 2030) standing alone, before a function word or before a capitalised name reads
    /// as one ("It was 1984.", "1066 William"); "2048." and "1500 people" are counts, and so
    /// is a number before an all-caps unit ("1500 MB", "1600 MHz").
    public static func readsAsYear(_ value: UInt64, previous: String?, next: String?) -> Bool {
        if let next, eras.contains(next.lowercased()) { return true }
        if let previous {
            let cue = previous.lowercased()
            if months.contains(cue) || yearCues.contains(cue) || yearPrepositions.contains(cue) { return true }
        }
        guard value <= 2030 else { return false }
        guard let next, let first = next.first else { return true }
        if first.isUppercase {
            // A title-case name follows a year; an all-caps or mixed unit follows a count.
            return next.dropFirst().allSatisfy(\.isLowercase)
        }
        return functionWords.contains(next.lowercased())
    }
}
