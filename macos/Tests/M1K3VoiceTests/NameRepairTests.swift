//
//  NameRepairTests.swift
//  M1K3VoiceTests
//
//  Pins NameRepair on the cases the spike measured (docs/evals/2026-10-15-stt.md):
//  the misheard names it fixes, the traps it must leave alone, and the ambiguity
//  it must refuse rather than guess (a wrong name is worse than a garbled one).
//
//  Signed: Kev + claude-opus-5-5, 2026-10-15, Confidence 0.8. Prior: Unknown.
//  Review: Kev + claude-opus-5-5, 2026-10-17 — an ordinary English word in the list ("Local", from a branding
//  line in memory) is locked but never a target: it swapped a rightly heard "Rachel" (#627). The guard tests
//  inject no word check, so they stay hermetic. Confidence 0.85.

@testable import M1K3Voice
import Testing

struct NameRepairTests {
    /// The guards' tests run without the OS word check, so they pin the guards (and don't move with the OS
    /// vocabulary): "inch" stays because the trap guard holds, not because "Inch" stopped being a target.
    static let noWordCheck: @Sendable ([String]) -> Set<String> = { _ in [] }

    /// The corpus names plus distractors: most of a real list never comes up.
    private let names = [
        "Carrauntoohil", "Dún Laoghaire", "Clonakilty", "Gougane Barra", "Aoife", "Oisín", "Ballybunion",
        "PhosphorFox", "SwiftUI", "Liquid Glass", "Kokoro", "Claude", "Schull", "Colm", "Bandon", "Lahinch",
        "Mallow", "Kilkee", "Saoirse", "Fionnuala", "Naoise", "Clodagh", "Skibbereen", "Macroom",
        "Ballincollig", "Castletownbere", "Inch",
    ]

    private func repaired(_ text: String) -> String {
        NameRepair(names: names, ordinaryWords: Self.noWordCheck).repair(text).text
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
        let repair = NameRepair(names: ["Sinéad", "Shinead"], ordinaryWords: Self.noWordCheck).repair("I met Shinade yesterday.")
        #expect(repair.text == "I met Shinade yesterday.")
        #expect(repair.repairs.isEmpty)
    }

    @Test("each repair reports what was heard, the name and the score")
    func repairsAreReported() throws {
        let result = NameRepair(names: names, ordinaryWords: Self.noWordCheck).repair("The ferry from Don Leary leaves at eight.")
        let repair = try #require(result.repairs.first)
        #expect(result.repairs.count == 1)
        #expect(repair.heard == "Don Leary")
        #expect(repair.name == "Dún Laoghaire")
        #expect(repair.score >= NameRepair.defaultThreshold)
    }

    @Test("punctuation around a repaired span is kept, both sides")
    func punctuationIsKept() {
        #expect(repaired("He said \"Karen 2 Hill\" loudly.") == "He said \"Carrauntoohil\" loudly.")
        #expect(repaired("A day trip (Don Leary) is fine.") == "A day trip (Dún Laoghaire) is fine.")
        #expect(repaired("Have you climbed Karen 2 Hill?") == "Have you climbed Carrauntoohil?")
    }

    @Test("a possessive keeps its 's, and a known name's possessive is left alone")
    func possessivesKeepTheirS() {
        #expect(repaired("The beach at Bally Bunion's end.") == "The beach at Ballybunion's end.")
        #expect(repaired("I saw Colm's car.") == "I saw Colm's car.")
        // A recogniser's 's can be the end of the name itself.
        let allihies = NameRepair(names: ["Allihies"], ordinaryWords: Self.noWordCheck)
        #expect(allihies.repair("The pub in Alohi's was busy.").text == "The pub in Allihies was busy.")
    }

    @Test("a name listed twice still repairs")
    func duplicateNamesStillRepair() {
        let repair = NameRepair(names: ["Carrauntoohil", "Carrauntoohil", "carrauntoohil"], ordinaryWords: Self.noWordCheck)
        #expect(repair.repair("We climbed Karen 2 Hill.").text == "We climbed Carrauntoohil.")
    }

    @Test("text with nothing to repair comes back byte for byte")
    func untouchedTextIsVerbatim() {
        let text = "We left  at eight.\nCall me later,\tplease."
        #expect(repaired(text) == text)
    }

    @Test("a correct multi-word name is not reported as a repair")
    func correctNameIsNotARepair() {
        let result = NameRepair(names: names, ordinaryWords: Self.noWordCheck).repair("Check the Liquid Glass toolbar and Gougane Barra.")
        #expect(result.repairs.isEmpty)
        #expect(result.text == "Check the Liquid Glass toolbar and Gougane Barra.")
    }

    @Test("a short single word needs more than one swapped sound")
    func shortWordIsNotSwapped() {
        #expect(NameRepair(names: ["Colm"], ordinaryWords: Self.noWordCheck).repair("I told Cole about it.").text == "I told Cole about it.")
        #expect(NameRepair(names: ["Gráinne"], ordinaryWords: Self.noWordCheck).repair("Owen and Gron are here.").text == "Owen and Gráinne are here.")
    }

    @Test("a weekday stays even when a name sounds like it")
    func weekdayIsLocked() {
        #expect(NameRepair(names: ["Mundee"], ordinaryWords: Self.noWordCheck).repair("We met on Monday at noon.").text == "We met on Monday at noon.")
    }

    @Test("a near miss inside the margin is refused, outside it is taken")
    func marginDecides() {
        // "Dermid" sounds exactly like Diarmuid (1.0) and nearly like Dermot (0.83).
        let text = "I met Dermid today."
        #expect(NameRepair(names: ["Dermot", "Diarmuid"], margin: 0.2, ordinaryWords: Self.noWordCheck).repair(text).text == text)
        #expect(NameRepair(names: ["Dermot", "Diarmuid"], margin: 0.1, ordinaryWords: Self.noWordCheck).repair(text).text == "I met Diarmuid today.")
    }

    @Test("no names, no change")
    func emptyListIsIdentity() {
        let text = "We climbed Karen 2 Hill."
        #expect(NameRepair(names: [], ordinaryWords: Self.noWordCheck).repair(text).text == text)
    }

    @Test("the sound key folds spelling to sound")
    func soundKeyFolds() {
        #expect(NameRepair.soundKey("Siobhán") == NameRepair.soundKey("siovan"))
        #expect(NameRepair.soundKey("PhosphorFox") == NameRepair.soundKey("phosphor fox"))
        // The recogniser's guess and the name fold to the same sound: why the repair is confident.
        #expect(NameRepair.soundKey("Karen 2 Hill") == NameRepair.soundKey("Carrauntoohil"))
        #expect(NameRepair.soundKey("launch") != NameRepair.soundKey("Ballybunion"))
    }

    // MARK: - Ordinary words in the list (#627)

    /// The live bug: "Local" reached the list from a branding line in memory, and "Rachel" (rakal)
    /// is one sound from it (lakal), 0.80 against a 0.75 bar.
    private let rachel = "My sister Rachel is coming to stay next month."

    @Test("without the word check, an ordinary word in the list steals a rightly heard name")
    func ordinaryWordStealsWithoutTheCheck() {
        let repair = NameRepair(names: ["Local", "Aoife"], ordinaryWords: { _ in [] })
        #expect(repair.repair(rachel).text == "My sister Local is coming to stay next month.")
    }

    @Test("an ordinary English word in the list is never a target", arguments: ["Local", "Offline", "Cork"])
    func ordinaryWordIsNoTarget(word: String) {
        let repair = NameRepair(names: [word, "Aoife"], ordinaryWords: { Set($0.filter { $0 == word }) })
        #expect(repair.repair(rachel).text == rachel)
        #expect(repair.repair("We took the train from Kork.").text == "We took the train from Kork.")
    }

    @Test("an ordinary word in the list stays locked: it is never repaired toward something else")
    func ordinaryWordStaysLocked() {
        let repair = NameRepair(names: ["Local", "Locan"], ordinaryWords: { Set($0.filter { $0 == "Local" }) })
        #expect(repair.repair("Is the Local model ready?").text == "Is the Local model ready?")
    }

    @Test("names of several words are kept as targets even when a word is ordinary")
    func multiWordNamesStay() {
        let repair = NameRepair(names: ["Liquid Glass"], ordinaryWords: { words in Set(words) })
        #expect(repair.repair("Check the Liquid Glas toolbar.").text == "Check the Liquid Glass toolbar.")
    }

    @Test("a one-word name that isn't an ordinary word is still a target with the check on")
    func realNameStillATarget() {
        let repair = NameRepair(names: ["Local", "Clodagh"], ordinaryWords: { Set($0.filter { $0 == "Local" }) })
        #expect(repair.repair("I met Clodda at the station.").text == "I met Clodagh at the station.")
        #expect(repair.ordinaryWordsLocked == 1)
    }

    @Test("the default word check knows English words and not Irish names",
          .enabled(if: NameRepair.ordinaryEnglishWords(["local"]) == ["local"]))
    func defaultWordCheck() {
        // The OS vocabulary differs by release (CI runs an older macOS): pin only the clear cases.
        let ordinary = NameRepair.ordinaryEnglishWords(["Local", "Aoife", "Niamh", "Siobhán", "Carrauntoohil"])
        #expect(ordinary == ["Local"])
    }
}
