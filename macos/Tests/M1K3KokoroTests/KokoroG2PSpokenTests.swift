import Foundation
@testable import M1K3Kokoro
import Testing

/// #838 end to end, against the shipped dictionary: a written form speaks exactly
/// as its words do ("3rd" ≡ "third"), while the caption keeps the written text
/// (one `G2PWord` per expansion, its range over the original characters).
struct KokoroG2PSpokenTests {
    private static let g2p: KokoroG2P = // Loaded once: the dictionary is ~200k entries.
        (try? KokoroG2P.bundled()) ?? KokoroG2P(dictionary: [:])

    private func speaks(_ written: String, as spoken: String,
                        sourceLocation: SourceLocation = #_sourceLocation)
    {
        let got = Self.g2p.phonemeTokens(written)
        let want = Self.g2p.phonemeTokens(spoken)
        #expect(!want.isEmpty, "the expected reading is silent", sourceLocation: sourceLocation)
        #expect(got == want, "\"\(written)\" should speak as \"\(spoken)\"", sourceLocation: sourceLocation)
    }

    /// The caption words, as the substrings of the original text they cover.
    private func captionWords(_ text: String) -> [String] {
        let utf16 = Array(text.utf16)
        return Self.g2p.annotatedTokens(text).words.map {
            String(utf16CodeUnits: Array(utf16[$0.textRange]), count: $0.textRange.count)
        }
    }

    @Test("ordinals")
    func ordinals() {
        speaks("the 3rd time", as: "the third time")
        speaks("her 21st birthday", as: "her twenty first birthday")
        #expect(captionWords("the 3rd time") == ["the", "3rd", "time"])
    }

    @Test("a minus sign is spoken, a hyphen inside a word is not a minus")
    func minus() {
        speaks("It was -5 outside", as: "It was minus five outside")
        speaks("It was −5 outside", as: "It was minus five outside")
        speaks("(-12)", as: "(minus twelve)")
        speaks("-5°C", as: "minus five celsius")
        speaks("10−3", as: "ten minus three")
        #expect(captionWords("It was -5 outside") == ["It", "was", "-5", "outside"])
    }

    @Test("currency")
    func currency() {
        speaks("It costs £5.", as: "It costs five pounds.")
        speaks("$20 each", as: "twenty dollars each")
        speaks("€3.50", as: "three euros fifty")
        speaks("only $0.99", as: "only ninety nine cents")
        speaks("£5 million", as: "five million pounds")
        #expect(captionWords("It costs £5.") == ["It", "costs", "£5"])
        #expect(captionWords("£5 million").count == 2)
    }

    @Test("times and verse references")
    func colons() {
        speaks("at 10:30", as: "at ten thirty")
        speaks("at 10:05", as: "at ten oh five")
        speaks("at 10:00", as: "at ten o'clock")
        speaks("John 3:16", as: "John three sixteen")
        #expect(captionWords("at 10:30") == ["at", "10:30"])
        // A colon after a word is still a pause.
        speaks("Note: 5", as: "Note: five")
    }

    @Test("counts versus years")
    func countsVersusYears() {
        speaks("1500 people", as: "one thousand five hundred people")
        speaks("2048 tokens", as: "two thousand and forty eight tokens")
        speaks("In 1984 the", as: "In nineteen eighty four the")
        speaks("It was 1984.", as: "It was nineteen eighty four.")
    }

    @Test("ranges say to; a date chain stays as it was")
    func ranges() {
        speaks("1990–2000", as: "nineteen ninety to two thousand")
        speaks("1990 – 2000", as: "nineteen ninety to two thousand")
        speaks("pages 4-7", as: "pages four to seven")
        #expect(captionWords("pages 4-7") == ["pages", "4", "-", "7"])
        // An ISO date is a dash chain, not a range: no "to" anywhere.
        let date = Self.g2p.phonemeTokens("2026-11-15")
        let to = Self.g2p.phonemeTokens("to")
        #expect(!date.isEmpty)
        #expect(!Self.contains(date, to), "a date chain must not say 'to'")
    }

    @Test("fractions")
    func fractions() {
        speaks("1/2 a cup", as: "a half a cup")
        speaks("3/4 done", as: "three quarters done")
        #expect(captionWords("3/4 done") == ["3/4", "done"])
    }

    @Test("long digit strings are grouped with pauses")
    func grouped() {
        speaks("1234567890123", as: "one two three, four five six, seven eight nine, zero one two, three")
        #expect(captionWords("1234567890123") == ["1234567890123"])
    }

    @Test("Roman numerals after a cue")
    func roman() {
        speaks("Henry VIII", as: "Henry the eighth")
        speaks("Psalm XXIII", as: "Psalm twenty three")
        speaks("Book IV", as: "Book four")
        speaks("Elements I.47", as: "Elements book one, proposition forty seven")
        #expect(captionWords("Elements I.47") == ["Elements", "I.47"])
        // The pronoun is untouched, even after a cue word.
        speaks("Then I went", as: "Then I went")
        speaks("the book I read", as: "the book I read")
        speaks("Thanks John I will", as: "Thanks John I will")
        speaks("Henry I.", as: "Henry the first.")
    }

    @Test("versions")
    func versions() {
        speaks("v1.2.3", as: "version one point two point three")
        speaks("update to 1.2.3", as: "update to one point two point three")
        #expect(captionWords("v1.2.3") == ["v1.2.3"])
        // A decimal stays a decimal.
        speaks("2.5", as: "two point five")
    }

    @Test("every rule keeps the karaoke contract: word ranges tile the written words")
    func rangesStayExact() {
        let text = "On 3rd May, -5 at 10:30 cost £5 for 1500 people, pages 4-7, 3/4 of Henry VIII v1.2.3."
        let words = captionWords(text)
        #expect(words == ["On", "3rd", "May", "-5", "at", "10:30", "cost", "£5", "for", "1500", "people",
                          "pages", "4", "-", "7", "3/4", "of", "Henry", "VIII", "v1.2.3"])
        for word in Self.g2p.annotatedTokens(text).words {
            #expect(!word.tokenRange.isEmpty, "a word went silent")
        }
    }

    private static func contains(_ haystack: [Int], _ needle: [Int]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        return (0 ... haystack.count - needle.count).contains { Array(haystack[$0 ..< $0 + needle.count]) == needle }
    }
}
