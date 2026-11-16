//
//  VoiceTurnWiringTests.swift
//  M1K3VoiceTests
//
//  Pins the pieces that wire NameRepair and SoundContext into a voice turn:
//  KnownNames (where the names come from), SoundContextGate (when the room line
//  reaches the brain: alerts every turn, the rest on change) and VoiceTurnPreparer
//  (repair the transcript, gate the line, and log the song verdict in shadow:
//  never drop the turn).
//
//  Signed: Kev + claude-opus-5-5, 2026-10-16, Confidence 0.8. Prior: Unknown.
//  (Review fold, same day: the gate commits only on delivery, KnownNames sheds openers, the kill switch.)
//  Review: Kev + claude-opus-5-5, 2026-11-16 (#852) — the heard line: every turn, ahead of the room line, its kill
//  switch, its wording rules, and a scan that both shells hand the brain `turnClause`.

import Foundation
@testable import M1K3Voice
import Testing

struct KnownNamesTests {
    @Test("names come from capitalised runs in memory facts, not from sentence openers")
    func extractsNames() {
        let names = KnownNames.from(
            facts: [
                "The user climbed Carrauntoohil last summer.",
                "Their sister Aoife lives in Dún Laoghaire.",
                "Kev's dog is called Bran.",
                "Prefers short answers.",
            ],
            userName: "Kev Murphy"
        )
        #expect(Set(names) == ["Kev Murphy", "Carrauntoohil", "Aoife", "Dún Laoghaire", "Bran"])
    }

    @Test("a two-word run opening a sentence counts; one opener word, a short word or a digit does not")
    func openerAndNoise() {
        let names = KnownNames.from(facts: ["Lough Hyne is near Skibbereen. Uses M1K3 and AI daily."], userName: nil)
        #expect(Set(names) == ["Lough Hyne", "Skibbereen"])
    }

    @Test("a verb or opener leading a sentence's run is not part of the name")
    func shedsOpeners() {
        let names = KnownNames.from(facts: ["Prefers Python for scripting.", "The Burren is lovely."], userName: nil)
        #expect(Set(names) == ["Python", "Burren"])
    }

    @Test("a first name ending in s survives a sentence start (#618 review)")
    func keepsNamesEndingInS() {
        let names = KnownNames.from(facts: ["Charles Murphy is Kev's uncle.", "Thomas Kelly plays hurling."], userName: nil)
        #expect(Set(names) == ["Charles Murphy", "Kev", "Thomas Kelly"])
    }

    @Test("past the limit the earliest facts win: the store hands them over newest first")
    func limitKeepsNewest() {
        /// Letters only: a word with a digit is never a name.
        func word(_ index: Int) -> String {
            let letters = Array("abcdefghijklmnopqrstuvwxyz")
            return "Bally" + String(letters[index / 26]) + String(letters[index % 26])
        }
        let facts = (0 ..< KnownNames.limit + 20).map { "Visited \(word($0))." }
        let names = KnownNames.from(facts: ["Talks to Aoife."] + facts, userName: nil)
        #expect(names.count == KnownNames.limit)
        #expect(names.first == "Aoife")
    }

    @Test("each name once, the user's first")
    func dedupes() {
        let names = KnownNames.from(facts: ["Talks to Aoife.", "Aoife rang about Aoife's car."], userName: "Aoife")
        #expect(names == ["Aoife"])
    }
}

struct SoundContextGateTests {
    private func heard(_ windows: [[String: Double]]) -> SoundContext {
        var context = SoundContext()
        for window in windows {
            context.observe(window)
        }
        return context
    }

    @Test("the room line reaches the brain once, then again only when it changes")
    func onChange() {
        var gate = SoundContextGate()
        let music = heard([["music": 0.9, "speech": 0.9], ["music": 0.9]])
        let quiet = heard([["speech": 0.9]])
        let first = gate.clause(for: music)
        #expect(first?.contains("music") == true)
        gate.commit(music)
        #expect(gate.clause(for: music) == nil)
        #expect(gate.clause(for: quiet) == nil)
        gate.commit(quiet)
        #expect(gate.clause(for: music) == first)
    }

    @Test("a line whose turn never reached the brain is still said next turn")
    func undelivered() {
        let gate = SoundContextGate()
        let music = heard([["music": 0.9, "speech": 0.9], ["music": 0.9]])
        #expect(gate.clause(for: music) != nil)
        #expect(gate.clause(for: music) != nil)
    }

    @Test("an alert is said every turn")
    func alertsRepeat() {
        var gate = SoundContextGate()
        let alarm = heard([["smoke_detector": 0.95, "speech": 0.9]])
        #expect(alarm.hasAlert)
        #expect(gate.clause(for: alarm)?.contains("a smoke alarm") == true)
        gate.commit(alarm)
        #expect(gate.clause(for: alarm)?.contains("a smoke alarm") == true)
    }

    @Test("no context, no clause")
    func nothingHeard() {
        let gate = SoundContextGate()
        #expect(gate.clause(for: nil) == nil)
    }
}

@MainActor
struct VoiceTurnPreparerTests {
    @Test("a misheard name is repaired before the turn runs")
    func repairsNames() {
        let preparer = VoiceTurnPreparer()
        preparer.learnNames(["Carrauntoohil"])
        let prepared = preparer.prepare("Have you climbed Karen 2 Hill?", heard: nil)
        #expect(prepared.question == "Have you climbed Carrauntoohil?")
        #expect(prepared.soundClause == nil)
    }

    @Test("-voiceNameRepair NO turns the repair off; anything else leaves it on")
    func killSwitch() {
        #expect(!VoiceTurnPreparer.nameRepairEnabled(arguments: ["voiceNameRepair": "NO"]))
        #expect(VoiceTurnPreparer.nameRepairEnabled(arguments: ["voiceNameRepair": "YES"]))
        #expect(VoiceTurnPreparer.nameRepairEnabled(arguments: [:]))
    }

    @Test("a delivered turn's room line isn't repeated; an undelivered one is")
    func deliveredCommits() {
        var music = SoundContext()
        music.observe(["music": 0.9, "speech": 0.9])
        music.observe(["music": 0.9])
        let preparer = VoiceTurnPreparer()
        let dropped = preparer.prepare("one", heard: music)
        #expect(dropped.soundClause != nil)
        let sent = preparer.prepare("two", heard: music)
        #expect(sent.soundClause != nil)
        preparer.delivered(sent)
        #expect(preparer.prepare("three", heard: music).soundClause == nil)
    }

    @Test("with no names learned the transcript passes through untouched")
    func passesThrough() {
        #expect(VoiceTurnPreparer().prepare("Have you climbed Karen 2 Hill?", heard: nil).question
            == "Have you climbed Karen 2 Hill?")
    }

    @Test("shadow mode: a listen that reads as a song still runs as a turn, with its room line")
    func shadowTakesTheTurn() {
        var song = SoundContext()
        song.observe(["music": 0.95, "singing": 0.9])
        song.observe(["music": 0.95, "singing": 0.9])
        #expect(song.verdict == .musicWithoutSpeech)
        let prepared = VoiceTurnPreparer().prepare("hello darkness my old friend", heard: song)
        #expect(prepared.question == "hello darkness my old friend")
        #expect(prepared.soundClause?.contains("music (singing)") == true)
    }

    // #852: the brain is told a voice turn was heard, not typed.

    @Test("every voice turn tells the brain it was heard; the question itself is untouched")
    func heardLineEveryTurn() {
        let preparer = VoiceTurnPreparer(heardClause: true)
        let first = preparer.prepare("You're my curry keeping, are you well?", heard: nil)
        #expect(first.question == "You're my curry keeping, are you well?")
        #expect(first.turnClause == HeardClause.text)
        // Unlike the room line, it isn't said once and dropped: every voice turn was heard.
        preparer.delivered(first)
        #expect(preparer.prepare("and again", heard: nil).turnClause == HeardClause.text)
    }

    @Test("the room line rides after the heard line, in one clause")
    func heardThenRoom() throws {
        var music = SoundContext()
        music.observe(["music": 0.9, "speech": 0.9])
        music.observe(["music": 0.9])
        let prepared = VoiceTurnPreparer(heardClause: true).prepare("what's this song", heard: music)
        let sound = try #require(prepared.soundClause)
        #expect(prepared.turnClause == HeardClause.text + "\n" + sound)
    }

    @Test("-voiceHeardClause NO drops the heard line and keeps the room line; anything else leaves it on")
    func heardKillSwitch() {
        #expect(!VoiceTurnPreparer.heardClauseEnabled(arguments: ["voiceHeardClause": "NO"]))
        #expect(!VoiceTurnPreparer.heardClauseEnabled(arguments: ["voiceHeardClause": "off"]))
        #expect(VoiceTurnPreparer.heardClauseEnabled(arguments: ["voiceHeardClause": "YES"]))
        #expect(VoiceTurnPreparer.heardClauseEnabled(arguments: [:]))
        #expect(VoiceTurnPreparer(heardClause: false).prepare("hello", heard: nil).turnClause == nil)
    }
}

struct HeardClauseTests {
    @Test("the line says the words were heard and may be misheard, and how to answer anyway")
    func saysWhatAndHow() {
        let text = HeardClause.text.lowercased()
        #expect(text.contains("spoken"))
        #expect(text.contains("mishear"))
        #expect(text.contains("most likely meant"))
        #expect(text.contains("ask"))
    }

    @Test("no wording carries an example from the heard eval: it can't be tuned to its own test")
    func noFixtureWords() {
        for text in [HeardClause.text, HeardClause.secondWording].map({ $0.lowercased() }) {
            for word in ["curry", "keeping", "craic", "galway", "giving out", "penny", "jupiter"] {
                #expect(!text.contains(word), "\(word)")
            }
        }
    }

    @Test("the eval arm picks a wording: off is none, v2 the second, anything else the shipped one")
    func armPicksWording() {
        #expect(HeardClause.forArm("off") == nil)
        #expect(HeardClause.forArm("v2") == HeardClause.secondWording)
        #expect(HeardClause.forArm(nil) == HeardClause.text)
        #expect(HeardClause.forArm("on") == HeardClause.text)
        #expect(HeardClause.secondWording != HeardClause.text)
    }
}

/// Both shells hand the brain the whole voice clause, not the room line alone (#852): a shell that kept
/// `soundClause` would compile, pass every test above and never say the turn was heard.
struct VoiceTurnClauseShellScanTests {
    private static func code(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("Mac and iPhone put prepared.turnClause in the turn's clause slot", arguments: [
        "M1K3App/AppEnvironment+VoiceMode.swift", "M1K3iOSApp/AppCore+Voice.swift",
    ])
    func shellsSetTurnClause(path: String) throws {
        let text = try Self.code(path)
        #expect(text.contains("voiceTurnClause.set(prepared.turnClause)"), "\(path)")
        #expect(!text.contains("voiceTurnClause.set(prepared.soundClause)"), "\(path)")
    }
}
