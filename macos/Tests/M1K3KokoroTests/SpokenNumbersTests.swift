import Foundation
@testable import M1K3Kokoro
import Testing

/// #838: the words each written form should be SPOKEN as. Pure: no dictionary.
/// The walker tests (`KokoroG2PSpokenTests`) check the same rules end to end.
struct SpokenNumbersTests {
    @Test("ordinals: 1st, 2nd, 3rd, 21st, 112th, 1000th")
    func ordinals() {
        #expect(SpokenNumbers.ordinal("1st") == ["first"])
        #expect(SpokenNumbers.ordinal("2nd") == ["second"])
        #expect(SpokenNumbers.ordinal("3rd") == ["third"])
        #expect(SpokenNumbers.ordinal("4TH") == ["fourth"])
        #expect(SpokenNumbers.ordinal("12th") == ["twelfth"])
        #expect(SpokenNumbers.ordinal("21st") == ["twenty", "first"])
        #expect(SpokenNumbers.ordinal("40th") == ["fortieth"])
        #expect(SpokenNumbers.ordinal("112th") == ["one", "hundred", "and", "twelfth"])
        #expect(SpokenNumbers.ordinal("1000th") == ["one", "thousandth"])
        // Not ordinals: a bare suffix, a wrong-looking shape, letters before digits.
        #expect(SpokenNumbers.ordinal("th") == nil)
        #expect(SpokenNumbers.ordinal("3x") == nil)
        #expect(SpokenNumbers.ordinal("a3rd") == nil)
    }

    @Test("a year-shaped ordinal is a count: 1500th is not 'fifteen hundredth'")
    func ordinalNeverYear() {
        #expect(SpokenNumbers.ordinal("1500th") == ["one", "thousand", "five", "hundredth"])
    }

    @Test("currency: £5, $20, €3.50, $0.99, £1, £0.01, £1.5, £1,000")
    func currency() {
        #expect(SpokenNumbers.currency(symbol: "£", literal: "5")?.all == ["five", "pounds"])
        #expect(SpokenNumbers.currency(symbol: "£", literal: "1")?.all == ["one", "pound"])
        #expect(SpokenNumbers.currency(symbol: "$", literal: "20")?.all == ["twenty", "dollars"])
        #expect(SpokenNumbers.currency(symbol: "€", literal: "3.50")?.all == ["three", "euros", "fifty"])
        #expect(SpokenNumbers.currency(symbol: "$", literal: "2.99")?.all == ["two", "dollars", "ninety", "nine"])
        #expect(SpokenNumbers.currency(symbol: "$", literal: "0.99")?.all == ["ninety", "nine", "cents"])
        #expect(SpokenNumbers.currency(symbol: "£", literal: "0.50")?.all == ["fifty", "pence"])
        #expect(SpokenNumbers.currency(symbol: "£", literal: "0.01")?.all == ["one", "penny"])
        #expect(SpokenNumbers.currency(symbol: "€", literal: "0.01")?.all == ["one", "cent"])
        #expect(SpokenNumbers.currency(symbol: "£", literal: "5.00")?.all == ["five", "pounds"])
        #expect(SpokenNumbers.currency(symbol: "£", literal: "1.5")?.all == ["one", "point", "five", "pounds"])
        #expect(SpokenNumbers.currency(symbol: "£", literal: "1,000")?.all == ["one", "thousand", "pounds"])
        // An amount is never a year: $2048 is a count.
        #expect(SpokenNumbers.currency(symbol: "$", literal: "2048")?.all
            == ["two", "thousand", "and", "forty", "eight", "dollars"])
        #expect(SpokenNumbers.currency(symbol: "£", literal: "abc") == nil)
        #expect(SpokenNumbers.currency(symbol: "¤", literal: "5") == nil)
    }

    @Test("currency before a scale word defers its unit: £5 million → five million pounds")
    func currencyUnitSplit() throws {
        let five = try #require(SpokenNumbers.currency(symbol: "£", literal: "5"))
        #expect(five.amount == ["five"])
        #expect(five.unit == ["pounds"])
        #expect(SpokenNumbers.isScaleWord("million"))
        #expect(SpokenNumbers.isScaleWord("bn") == false)
    }

    @Test("clock and reference colons: 10:30, 10:05, 10:00, John 3:16")
    func colons() {
        #expect(SpokenNumbers.colon("10:30") == ["ten", "thirty"])
        #expect(SpokenNumbers.colon("10:05") == ["ten", "oh", "five"])
        #expect(SpokenNumbers.colon("10:00") == ["ten", "o'clock"])
        #expect(SpokenNumbers.colon("3:16") == ["three", "sixteen"])
        #expect(SpokenNumbers.colon("3:5") == ["three", "five"])
        // A big left side is not a clock: no o'clock.
        #expect(SpokenNumbers.colon("100:00") == ["one", "hundred", "zero"])
        #expect(SpokenNumbers.colon("10:30:15") == nil)
        #expect(SpokenNumbers.colon("10:") == nil)
    }

    @Test("fractions: 1/2, 3/4, 2/3, 1/7, 3/7, 5/16, 24/7")
    func fractions() {
        #expect(SpokenNumbers.fraction("1/2") == ["a", "half"])
        #expect(SpokenNumbers.fraction("3/2") == ["three", "halves"])
        #expect(SpokenNumbers.fraction("1/4") == ["a", "quarter"])
        #expect(SpokenNumbers.fraction("3/4") == ["three", "quarters"])
        #expect(SpokenNumbers.fraction("2/3") == ["two", "thirds"])
        #expect(SpokenNumbers.fraction("1/5") == ["a", "fifth"])
        #expect(SpokenNumbers.fraction("1/7") == ["a", "seventh"])
        // "sevenths" is not in the dictionary, so a plural seventh says "over".
        #expect(SpokenNumbers.fraction("3/7") == ["three", "over", "seven"])
        #expect(SpokenNumbers.fraction("9/10") == ["nine", "tenths"])
        #expect(SpokenNumbers.fraction("5/16") == ["five", "over", "sixteen"])
        #expect(SpokenNumbers.fraction("24/7") == ["twenty", "four", "seven"])
        #expect(SpokenNumbers.fraction("1/0") == ["one", "over", "zero"])
        #expect(SpokenNumbers.fraction("1/2/3") == nil)
    }

    @Test("ranges say 'to'; a dash chain (a date) does not")
    func ranges() {
        #expect(SpokenNumbers.rangeWord == "to")
    }

    @Test("versions: v1.2.3, 1.2.3, v2, v2.1, 1.2.10")
    func versions() {
        #expect(SpokenNumbers.version("v1.2.3") == ["version", "one", "point", "two", "point", "three"])
        #expect(SpokenNumbers.version("1.2.3") == ["one", "point", "two", "point", "three"])
        #expect(SpokenNumbers.version("v2") == ["version", "two"])
        #expect(SpokenNumbers.version("v2.1") == ["version", "two", "point", "one"])
        #expect(SpokenNumbers.version("1.2.10") == ["one", "point", "two", "point", "ten"])
        // A plain decimal is a number, not a version; an uppercase V is not "version".
        #expect(SpokenNumbers.version("2.5") == nil)
        #expect(SpokenNumbers.version("V8") == nil)
        #expect(SpokenNumbers.version("v") == nil)
        #expect(SpokenNumbers.version("v1..2") == nil)
    }

    @Test("Roman numeral values: canonical forms only")
    func romanValues() {
        #expect(SpokenNumbers.romanValue("I") == 1)
        #expect(SpokenNumbers.romanValue("IV") == 4)
        #expect(SpokenNumbers.romanValue("VIII") == 8)
        #expect(SpokenNumbers.romanValue("XXIII") == 23)
        #expect(SpokenNumbers.romanValue("XIV") == 14)
        #expect(SpokenNumbers.romanValue("MCMLXXXIV") == 1984)
        #expect(SpokenNumbers.romanValue("IIII") == nil)
        #expect(SpokenNumbers.romanValue("IIV") == nil)
        #expect(SpokenNumbers.romanValue("VX") == nil)
        #expect(SpokenNumbers.romanValue("iv") == nil)
        #expect(SpokenNumbers.romanValue("") == nil)
    }

    @Test("Roman numerals read only after a cue word")
    func romanCues() {
        #expect(SpokenNumbers.roman("VIII", previous: "Henry") == ["the", "eighth"])
        #expect(SpokenNumbers.roman("II", previous: "Elizabeth") == ["the", "second"])
        #expect(SpokenNumbers.roman("I", previous: "Mary") == ["the", "first"])
        #expect(SpokenNumbers.roman("XXIII", previous: "Psalm") == ["twenty", "three"])
        #expect(SpokenNumbers.roman("IV", previous: "Book") == ["four"])
        #expect(SpokenNumbers.roman("II", previous: "War") == ["two"])
        #expect(SpokenNumbers.roman("LVII", previous: "Bowl") == ["fifty", "seven"])
        #expect(SpokenNumbers.roman("I", previous: "Elements") == ["book", "one"])
        // No cue, no reading: the pronoun, acronyms and vitamins stay as they are.
        #expect(SpokenNumbers.roman("I", previous: "Then") == nil)
        #expect(SpokenNumbers.roman("I", previous: nil) == nil)
        #expect(SpokenNumbers.roman("CD", previous: "the") == nil)
        #expect(SpokenNumbers.roman("D", previous: "Vitamin") == nil)
        // A lone C, D, L or M after a cardinal cue is a label, not a number: "Appendix C".
        #expect(SpokenNumbers.roman("C", previous: "Appendix") == nil)
        #expect(SpokenNumbers.roman("D", previous: "Part") == nil)
        #expect(SpokenNumbers.roman("V", previous: "Part") == ["five"])
        // Lowercase is never a numeral.
        #expect(SpokenNumbers.roman("iv", previous: "Book") == nil)
    }

    @Test("a lone I stays the pronoun unless a capitalised cue leads and no lowercase word follows")
    func romanOneIsUsuallyThePronoun() {
        #expect(SpokenNumbers.roman("I", previous: "book", next: "read") == nil)
        #expect(SpokenNumbers.roman("I", previous: "John", next: "will") == nil)
        #expect(SpokenNumbers.roman("I", previous: "Henry", next: "was") == nil)
        #expect(SpokenNumbers.roman("I", previous: "Henry", next: nil) == ["the", "first"])
        #expect(SpokenNumbers.roman("I", previous: "Part", next: "Introduction") == ["one"])
        // Longer numerals are never the pronoun.
        #expect(SpokenNumbers.roman("IV", previous: "book", next: "says") == ["four"])
    }

    @Test("Euclid references: Elements I.47 → book one, proposition forty-seven")
    func euclid() {
        #expect(SpokenNumbers.euclid(book: "I", proposition: "47")
            == ["book", "one", ",", "proposition", "forty", "seven"])
        #expect(SpokenNumbers.euclid(book: "IIII", proposition: "47") == nil)
    }

    @Test("a year reading needs a year's context; a count before a noun is a count")
    func yearOrCount() {
        // Counts: a lowercase content word follows.
        #expect(SpokenNumbers.readsAsYear(previous: nil, next: "people") == false)
        #expect(SpokenNumbers.readsAsYear(previous: "about", next: "tokens") == false)
        // Years: nothing follows, a function word follows, an era follows, or a year cue leads.
        #expect(SpokenNumbers.readsAsYear(previous: "in", next: nil))
        #expect(SpokenNumbers.readsAsYear(previous: nil, next: "the"))
        #expect(SpokenNumbers.readsAsYear(previous: nil, next: "BC"))
        #expect(SpokenNumbers.readsAsYear(previous: "March", next: "saw"))
        #expect(SpokenNumbers.readsAsYear(previous: "since", next: "was"))
        #expect(SpokenNumbers.readsAsYear(previous: nil, next: "William"))
    }

    @Test("integerWords can skip the year reading")
    func yearReadingSwitch() {
        #expect(NumberSpeller.integerWords("1500") == ["fifteen", "hundred"])
        #expect(NumberSpeller.integerWords("1500", yearReading: false) == ["one", "thousand", "five", "hundred"])
        #expect(NumberSpeller.numberWords("2048", yearReading: false) == ["two", "thousand", "and", "forty", "eight"])
    }

    @Test("every word the rules emit is in the shipped dictionary")
    func vocabularyResolves() throws {
        let dictionary = try KokoroG2P.bundledDictionary()
        let samples: [[String]?] = [
            SpokenNumbers.ordinal("1st"), SpokenNumbers.ordinal("2nd"), SpokenNumbers.ordinal("3rd"),
            SpokenNumbers.ordinal("5th"), SpokenNumbers.ordinal("8th"), SpokenNumbers.ordinal("9th"),
            SpokenNumbers.ordinal("12th"), SpokenNumbers.ordinal("13th"), SpokenNumbers.ordinal("20th"),
            SpokenNumbers.ordinal("30th"), SpokenNumbers.ordinal("50th"), SpokenNumbers.ordinal("100th"),
            SpokenNumbers.ordinal("1000th"), SpokenNumbers.ordinal("1000000th"), SpokenNumbers.ordinal("0th"),
            SpokenNumbers.currency(symbol: "£", literal: "1.01")?.all, SpokenNumbers.currency(symbol: "£", literal: "2.50")?.all,
            SpokenNumbers.currency(symbol: "£", literal: "0.01")?.all, SpokenNumbers.currency(symbol: "$", literal: "1.01")?.all,
            SpokenNumbers.currency(symbol: "$", literal: "2")?.all, SpokenNumbers.currency(symbol: "€", literal: "1")?.all,
            SpokenNumbers.currency(symbol: "€", literal: "2.02")?.all,
            SpokenNumbers.colon("10:00"), SpokenNumbers.colon("10:05"),
            SpokenNumbers.fraction("1/2"), SpokenNumbers.fraction("3/2"), SpokenNumbers.fraction("2/3"),
            SpokenNumbers.fraction("3/4"), SpokenNumbers.fraction("2/5"), SpokenNumbers.fraction("5/6"),
            SpokenNumbers.fraction("1/7"), SpokenNumbers.fraction("3/7"), SpokenNumbers.fraction("3/8"),
            SpokenNumbers.fraction("4/9"), SpokenNumbers.fraction("7/10"), SpokenNumbers.fraction("1/16"),
            SpokenNumbers.version("v1.2.3"), [SpokenNumbers.rangeWord, "minus"],
            SpokenNumbers.roman("VIII", previous: "Henry"), SpokenNumbers.euclid(book: "I", proposition: "47"),
        ]
        for words in samples {
            let words = try #require(words)
            for word in words where word != "," {
                #expect(dictionary[word] != nil, "\(word) is not in the dictionary")
            }
        }
    }
}
