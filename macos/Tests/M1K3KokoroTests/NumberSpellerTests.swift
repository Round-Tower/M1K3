import M1K3Kokoro
import Testing

struct NumberSpellerTests {
    // MARK: - Single digits and teens

    @Test("single digits")
    func singleDigits() {
        #expect(NumberSpeller.integerWords("0") == ["zero"])
        #expect(NumberSpeller.integerWords("5") == ["five"])
        #expect(NumberSpeller.integerWords("9") == ["nine"])
    }

    @Test("teens and tens")
    func teensAndTens() {
        #expect(NumberSpeller.integerWords("15") == ["fifteen"])
        #expect(NumberSpeller.integerWords("42") == ["forty", "two"])
        #expect(NumberSpeller.integerWords("90") == ["ninety"])
        #expect(NumberSpeller.integerWords("10") == ["ten"])
    }

    // MARK: - Hundreds (en-GB "and")

    @Test("hundreds use the GB and")
    func hundreds() {
        #expect(NumberSpeller.integerWords("123") == ["one", "hundred", "and", "twenty", "three"])
        #expect(NumberSpeller.integerWords("100") == ["one", "hundred"])
        #expect(NumberSpeller.integerWords("205") == ["two", "hundred", "and", "five"])
    }

    // MARK: - Thousands and beyond

    @Test("thousands and millions")
    func thousandsAndMillions() {
        #expect(NumberSpeller.integerWords("12000") == ["twelve", "thousand"])
        #expect(NumberSpeller.integerWords("3000000") == ["three", "million"])
        #expect(NumberSpeller.integerWords("1000001") == ["one", "million", "and", "one"])
    }

    @Test("more than twelve digits read digit by digit, grouped in threes with a pause (#838)")
    func hugeNumbersDigitByDigit() {
        #expect(NumberSpeller.integerWords("1234567890123") == [
            "one", "two", "three", ",", "four", "five", "six", ",", "seven", "eight", "nine", ",",
            "zero", "one", "two", ",", "three",
        ])
    }

    // MARK: - Years

    @Test("years read as pairs")
    func yearPairs() {
        #expect(NumberSpeller.integerWords("2026") == ["twenty", "twenty", "six"])
        #expect(NumberSpeller.integerWords("1984") == ["nineteen", "eighty", "four"])
        #expect(NumberSpeller.integerWords("2007") == ["twenty", "oh", "seven"])
    }

    @Test("round years read naturally, not as pairs")
    func roundYears() {
        #expect(NumberSpeller.integerWords("2000") == ["two", "thousand"])
        #expect(NumberSpeller.integerWords("1900") == ["nineteen", "hundred"])
        #expect(NumberSpeller.integerWords("1000") == ["one", "thousand"])
    }

    @Test("four-digit numbers outside the year band read as quantities")
    func nonYearFourDigits() {
        #expect(NumberSpeller.integerWords("4500") == ["four", "thousand", "five", "hundred"])
    }

    // MARK: - numberWords (literals)

    @Test("decimals speak the fraction digit by digit")
    func decimals() {
        #expect(NumberSpeller.numberWords("3.5") == ["three", "point", "five"])
        #expect(NumberSpeller.numberWords("0.25") == ["zero", "point", "two", "five"])
    }

    @Test("grouping commas are stripped")
    func groupingCommas() {
        #expect(NumberSpeller.numberWords("1,000") == ["one", "thousand"])
    }

    @Test("plain integers route through integerWords")
    func plainIntegerLiteral() {
        #expect(NumberSpeller.numberWords("15") == ["fifteen"])
    }

    @Test("non-numbers return nil")
    func nonNumbers() {
        #expect(NumberSpeller.numberWords("M1K3") == nil)
        #expect(NumberSpeller.numberWords("") == nil)
        #expect(NumberSpeller.numberWords("1.2.3") == nil)
    }

    @Test("digitWord maps single digit characters")
    func digitWords() {
        #expect(NumberSpeller.digitWord("0") == "zero")
        #expect(NumberSpeller.digitWord("7") == "seven")
        #expect(NumberSpeller.digitWord("x") == nil)
    }

    // MARK: - Closed vocabulary

    @Test("every emitted word belongs to the closed dictionary-safe set")
    func closedVocabulary() {
        let vocabulary: Set = [
            "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
            "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
            "seventeen", "eighteen", "nineteen",
            "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
            "hundred", "thousand", "million", "billion", "point", "and", "oh",
            ",", // the pause between digit groups (#838), a punctuation token, not a word
        ]
        let samples = ["0", "7", "15", "42", "99", "100", "123", "205", "999", "1000",
                       "1984", "2007", "2026", "4500", "12000", "999999", "3000000",
                       "1000001", "999999999999", "1234567890123"]
        for sample in samples {
            for word in NumberSpeller.integerWords(Substring(sample)) {
                #expect(vocabulary.contains(word), "\(word) from \(sample) not in closed set")
            }
        }
        for word in NumberSpeller.numberWords("12,345.678") ?? [] {
            #expect(vocabulary.contains(word))
        }
    }
}
