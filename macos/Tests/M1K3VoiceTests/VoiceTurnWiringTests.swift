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
}
