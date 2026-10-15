//
//  WordErrorRateTests.swift
//  M1K3EvalTests
//
//  Pins the speech-to-text scorer: formatting never counts as an error (case,
//  punctuation, a fada, "fifteen" vs "15", fillers), mishearing always does.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-15, Confidence 0.85. Prior: Unknown.
//  Review: claude-opus-5-5, 2026-10-15: Kev's first real corpus showed three formatting
//  gaps scored as errors: a digit run grouped differently, a currency, US spelling. Pinned.
//  Review: claude-opus-5-5, 2026-10-15: "one second" folded to 3rd (review catch). Pinned.

@testable import M1K3Eval
import Testing

struct WordErrorRateTests {
    private func errors(_ reference: String, _ hypothesis: String) -> Int {
        WordErrorRate.score(reference: reference, hypothesis: hypothesis).errors
    }

    @Test("identical text has no errors") func identicalTextHasNoErrors() {
        let score = WordErrorRate.score(reference: "read me the weather", hypothesis: "read me the weather")
        #expect(score.errors == 0)
        #expect(score.words == 4)
        #expect(score.rate == 0)
    }

    @Test("case and punctuation are formatting, not errors") func caseAndPunctuationAreFormatting() {
        #expect(errors(
            "Remind me to call the dentist tomorrow morning.", "remind me to call the dentist, tomorrow morning"
        ) == 0)
        #expect(errors("What's on my calendar for Friday?", "whats on my calendar for friday") == 0)
        #expect(errors("I’m running late", "I'm running late") == 0)
    }

    @Test("substitutions insertions and deletions each count once") func substitutionsInsertionsAndDeletionsEach() {
        #expect(errors("call the dentist", "call a dentist") == 1)
        #expect(errors("call the dentist", "call the the dentist") == 1)
        #expect(errors("call the dentist", "call dentist") == 1)
        #expect(errors("call the dentist", "") == 3)
    }

    @Test("a fada is spelling, not hearing") func aFadaIsSpellingNot() {
        #expect(errors("The ferry from Dún Laoghaire", "the ferry from dun laoghaire") == 0)
        #expect(errors("Aoife and Oisín", "aoife and oisin") == 0)
        // A different word is still wrong.
        #expect(errors("Dún Laoghaire", "dun leary") == 1)
    }

    @Test("spoken numbers match their digits") func spokenNumbersMatchTheirDigits() {
        #expect(errors("running about fifteen minutes late", "running about 15 minutes late") == 0)
        #expect(errors("four hundred and sixty-two euro fifty", "462 euro 50") == 0)
        #expect(errors("on the twenty-third of November", "on the 23rd of november") == 0)
        #expect(errors("make it twenty minutes", "make it 20 minutes") == 0)
        #expect(errors("at three", "at 3") == 0)
        // Digits read one by one are a digit string; a pause or comma ends the group.
        #expect(errors("zero eight seven, five five five, one two three four", "087 555 1234") == 0)
        // However the digits are grouped: Apple writes a phone number as one run (Kev's corpus).
        #expect(errors("zero eight seven, five five five, one two three four", "0875551234") == 0)
        #expect(errors("flight EI 712", "flight EI seven twelve") == 0)
        // An ordinal word after a digit word is its own number: "one second" is not "3rd".
        #expect(errors("give me one second", "give me 1 second") == 0)
        #expect(errors("one third of it", "1 third of it") == 0)
        // A wrong number is a wrong word.
        #expect(errors("fifteen minutes", "50 minutes") == 1)
    }

    @Test("a clock time matches however it is written")
    func clockTimesMatch() {
        #expect(errors("leaves at half past eight", "leaves at 8:30") == 0)
        #expect(errors("at quarter past three", "at 3:15") == 0)
        #expect(errors("at quarter to nine", "at 8:45") == 0)
        #expect(errors("at eight o'clock", "at 8:00") == 0)
        #expect(errors("at eight o'clock", "at 8") == 0)
        // A wrong time is wrong.
        #expect(errors("half past eight", "8:15") > 0)
    }

    @Test("a currency is formatting, said or symbolised")
    func aCurrencyIsFormatting() {
        #expect(errors("four hundred and sixty-two euro fifty", "€462.50") == 0)
        #expect(errors("it was twenty euros", "it was €20") == 0)
        #expect(errors("twenty euro", "twenty pounds") == 1)
    }

    @Test("American and Irish spelling are the same word")
    func americanAndIrishSpellingMatch() {
        #expect(errors("summarise the notes", "summarize the notes") == 0)
        #expect(errors("walk to the harbour", "walk to the harbor") == 0)
        #expect(errors("the colour of the sky", "the color of the sky") == 0)
        #expect(errors("walk to the harbour", "walk to the arbour") == 1)
    }

    @Test("fillers are dropped on both sides") func fillersAreDroppedOnBoth() {
        #expect(errors("Can you, um, find the article", "can you find the article") == 0)
        #expect(errors("can you find the article", "can you uh find the article") == 0)
    }

    @Test("an empty reference scores no words") func anEmptyReferenceScoresNo() {
        let score = WordErrorRate.score(reference: "", hypothesis: "")
        #expect(score.words == 0)
        #expect(score.rate == 0)
    }

    @Test("a corpus rate weights by words, not clips") func aCorpusRateWeightsBy() {
        let total = WordErrorRate.corpus([
            WordErrorRate.score(
                reference: "remind me to call the dentist tomorrow morning before ten",
                hypothesis: "remind me to call the dentist tomorrow morning before 10"
            ),
            WordErrorRate.score(reference: "short line", hypothesis: "sport line"),
        ])
        #expect(total.errors == 1)
        #expect(total.words == 12)
        #expect(abs(total.rate - 1.0 / 12.0) < 1e-9)
    }
}
