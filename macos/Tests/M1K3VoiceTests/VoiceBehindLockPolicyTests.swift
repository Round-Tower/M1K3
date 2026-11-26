import M1K3Voice
import Testing

/// A voice conversation on the iPhone keeps going when the phone locks (Kev, 2026-11-26: on by default, with a
/// switch; Home answers if paired, else Mini). iOS refuses GPU work behind the lock, so Lil and Big can't answer
/// there; the spike (spike/bg-voice, 2026-11-17) measured Mini at 8/8 re-listens.
struct VoiceBehindLockPolicyTests {
    @Test("the switch is on by default")
    func onByDefault() {
        #expect(VoiceBehindLockPolicy.onByDefault)
    }

    @Test("no voice conversation, or the switch off: the app leaves voice mode, as before")
    func nothingToKeep() {
        #expect(VoiceBehindLockPolicy.brain(
            switchOn: true, voiceModeActive: false, chosenRunsOnThisGPU: false, homePaired: true, miniAvailable: true
        ) == nil)
        #expect(VoiceBehindLockPolicy.brain(
            switchOn: false, voiceModeActive: true, chosenRunsOnThisGPU: false, homePaired: true, miniAvailable: true
        ) == nil)
    }

    @Test("a brain that runs off this GPU (Mini, Home, Private Cloud) keeps answering")
    func offGPUBrainStays() {
        #expect(VoiceBehindLockPolicy.brain(
            switchOn: true, voiceModeActive: true, chosenRunsOnThisGPU: false, homePaired: false, miniAvailable: false
        ) == .asChosen)
    }

    @Test("Lil or Big chosen: the paired Mac answers behind the lock")
    func homeWhenPaired() {
        #expect(VoiceBehindLockPolicy.brain(
            switchOn: true, voiceModeActive: true, chosenRunsOnThisGPU: true, homePaired: true, miniAvailable: true
        ) == .home)
    }

    @Test("Lil or Big chosen and no paired Mac: Mini answers")
    func miniWhenUnpaired() {
        #expect(VoiceBehindLockPolicy.brain(
            switchOn: true, voiceModeActive: true, chosenRunsOnThisGPU: true, homePaired: false, miniAvailable: true
        ) == .mini)
    }

    @Test("Lil or Big chosen, no Mac and no Mini: nobody can answer, so voice mode ends at the lock")
    func nobodyToAnswer() {
        #expect(VoiceBehindLockPolicy.brain(
            switchOn: true, voiceModeActive: true, chosenRunsOnThisGPU: true, homePaired: false, miniAvailable: false
        ) == nil)
    }

    @Test("a minute of silence behind the lock ends the conversation")
    func silenceEnds() {
        #expect(VoiceBehindLockPolicy.silenceLimit == .seconds(60))
        #expect(!VoiceBehindLockPolicy.endsForSilence(silentFor: .seconds(59), turnRunning: false))
        #expect(VoiceBehindLockPolicy.endsForSilence(silentFor: .seconds(60), turnRunning: false))
    }

    /// Spike run 2 (11-17): a 60 s web-search timeout ended the conversation mid-turn.
    @Test("a turn still running is not silence, however long it takes")
    func runningTurnIsNotSilence() {
        #expect(!VoiceBehindLockPolicy.endsForSilence(silentFor: .seconds(600), turnRunning: true))
    }

    /// In front, an interruption parks the loop until a tap. Behind the lock nobody can tap.
    @Test("behind the lock, an interruption that ends with shouldResume picks the listen back up")
    func resumesAfterInterruption() {
        #expect(VoiceBehindLockPolicy.resumesAfterInterruption(shouldResume: true, loop: .idle))
        #expect(!VoiceBehindLockPolicy.resumesAfterInterruption(shouldResume: false, loop: .idle))
        #expect(!VoiceBehindLockPolicy.resumesAfterInterruption(shouldResume: true, loop: .speaking(answer: "hi")))
        #expect(!VoiceBehindLockPolicy.resumesAfterInterruption(shouldResume: true, loop: .ended))
    }
}
