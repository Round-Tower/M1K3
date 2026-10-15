//
//  NameRepairTests.swift
//  M1K3VoiceTests
//
//  Pins NameRepair on the cases the spike measured (docs/evals/2026-10-15-stt.md):
//  the misheard names it fixes, the traps it must leave alone, and the ambiguity
//  it must refuse rather than guess (a wrong name is worse than a garbled one).
//
//  Signed: Kev + claude-opus-5-5, 2026-10-15, Confidence 0.8. Prior: Unknown.

@testable import M1K3Voice
import Testing

struct NameRepairTests {
    /// The corpus names plus distractors: most of a real list never comes up.
    private let names = [
        "Carrauntoohil", "Dún Laoghaire", "Clonakilty", "Gougane Barra", "Aoife", "Oisín", "Ballybunion",
        "PhosphorFox", "SwiftUI", "Liquid Glass", "Kokoro", "Claude", "Schull", "Colm", "Bandon", "Lahinch",
        "Mallow", "Kilkee", "Saoirse", "Fionnuala", "Naoise", "Clodagh", "Skibbereen", "Macroom",
        "Ballincollig", "Castletownbere", "Inch",
    ]

    private func repaired(_ text: String) -> String {
        NameRepair(names: names).repair(text).text
    }

    @Test("a misheard name becomes the known one", arguments: [
        ("We climbed Karen 2 Hill on the first dry Saturday in May.",
         "We climbed Carrauntoohil on the first dry Saturday in May."),
        ("The ferry from Don Leary leaves at eight.", "The ferry from Dún Laoghaire leaves at eight."),
        ("My cousin lives just outside Clinic Hill.", "My cousin lives just outside Clonakilty."),
        ("Is the road to Gubenbarra open after the storm?", "Is the road to Gougane Barra open after the storm?"),
        ("We stopped for chips in Bally Bunion.", "We stopped for chips in Ballybunion."),
        ("The bus from Macrome to Berlin College was late.", "The bus from Macroom to Ballincollig was late."),
    ])
    func misheardNameIsRepaired(heard: String, expected: String) {
        #expect(repaired(heard) == expected)
    }

    @Test("a lowercase run that sounds exactly like a name is repaired")
    func lowercaseExactSoundIsRepaired() {
        #expect(repaired("Remember the phosphor fox is my favourite.") == "Remember the PhosphorFox is my favourite.")
        #expect(repaired("Check the liquid glass toolbar.") == "Check the Liquid Glass toolbar.")
    }

    @Test("ordinary words that sound like a name stay", arguments: [
        "The kids walked to school in the rain.",
        "Stay calm and read me the next message.",
        "Don't abandon the draft, just shorten the ending.",
        "I roasted a marshmallow over the fire.",
        "Move the picture up an inch on the left.",
        "The launch went well, so let's celebrate tonight.",
    ])
    func trapsStay(text: String) {
        #expect(repaired(text) == text)
    }

    @Test("a capital that only opens a sentence is no evidence of a name")
    func sentenceStartIsNotAName() {
        #expect(repaired("Call me back on 0875551234.") == "Call me back on 0875551234.")
        #expect(repaired("Sorry. Call me later.") == "Sorry. Call me later.")
    }

    @Test("a known name, a weekday and a month are never swapped")
    func lockedWordsStay() {
        #expect(repaired("Copy the access token for Claude.") == "Copy the access token for Claude.")
        #expect(repaired("We met on Monday in May.") == "We met on Monday in May.")
    }

    @Test("an ambiguous span is left alone rather than guessed")
    func ambiguityIsRefused() {
        // Two known names sound alike to the heard word: guessing could store the wrong one.
        let repair = NameRepair(names: ["Sinéad", "Shinead"]).repair("I met Shinade yesterday.")
        #expect(repair.text == "I met Shinade yesterday.")
        #expect(repair.repairs.isEmpty)
    }

    @Test("each repair reports what was heard, the name and the score")
    func repairsAreReported() throws {
        let result = NameRepair(names: names).repair("The ferry from Don Leary leaves at eight.")
        let repair = try #require(result.repairs.first)
        #expect(result.repairs.count == 1)
        #expect(repair.heard == "Don Leary")
        #expect(repair.name == "Dún Laoghaire")
        #expect(repair.score >= NameRepair.defaultThreshold)
    }

    @Test("no names, no change")
    func emptyListIsIdentity() {
        let text = "We climbed Karen 2 Hill."
        #expect(NameRepair(names: []).repair(text).text == text)
    }

    @Test("the sound key folds spelling to sound")
    func soundKeyFolds() {
        #expect(NameRepair.soundKey("Siobhán") == NameRepair.soundKey("siovan"))
        #expect(NameRepair.soundKey("PhosphorFox") == NameRepair.soundKey("phosphor fox"))
        // The recogniser's guess and the name fold to the same sound: why the repair is confident.
        #expect(NameRepair.soundKey("Karen 2 Hill") == NameRepair.soundKey("Carrauntoohil"))
        #expect(NameRepair.soundKey("launch") != NameRepair.soundKey("Ballybunion"))
    }
}
