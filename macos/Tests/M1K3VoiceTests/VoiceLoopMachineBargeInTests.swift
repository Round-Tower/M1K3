import M1K3Voice
import Testing

/// Spoken barge-in in the reducer (#640), behind `bargeIn: true`. While M1K3 speaks
/// the mic stays open on a WATCH listen; a partial the policy accepts becomes the
/// next question's listen, keeping the words already heard. Off, the loop is the
/// half-duplex one VoiceLoopMachineTests pins (those tests run with the default).
struct VoiceLoopMachineBargeInTests {
    private func speaking(_ chunk: String = "One.") -> VoiceLoopMachine {
        var machine = VoiceLoopMachine(bargeIn: true)
        _ = machine.handle(.begin)
        _ = machine.handle(.endpointed("q"))
        _ = machine.handle(.answerChunk(chunk))
        return machine
    }

    @Test("the first chunk starts speaking AND opens the barge-in watch")
    func firstChunkWatches() {
        var machine = VoiceLoopMachine(bargeIn: true)
        _ = machine.handle(.begin)
        _ = machine.handle(.endpointed("q"))
        #expect(machine.handle(.answerChunk("One.")) == [.speak("One."), .watchForBargeIn])
        // Later chunks don't open a second watch.
        #expect(machine.handle(.answerChunk("Two.")) == [.speak("Two.")])
    }

    @Test("the whole-answer path watches too")
    func answerReadyWatches() {
        var machine = VoiceLoopMachine(bargeIn: true)
        _ = machine.handle(.begin)
        _ = machine.handle(.endpointed("q"))
        #expect(machine.handle(.answerReady("All of it.")) == [.speak("All of it."), .watchForBargeIn])
    }

    @Test("a barge-in stops the speech and adopts the watch as the listen, words kept, no echo grace")
    func bargeInAdoptsTheWatch() {
        var machine = speaking()
        #expect(machine.handle(.bargeIn("hang on")) == [.stopSpeaking, .adoptBargeInWatch])
        #expect(machine.state == .listening(partial: "hang on"))
        // The generator's later chunks are stale now, as after a click barge-in.
        #expect(machine.handle(.answerChunk("Two.")).isEmpty)
        #expect(machine.handle(.answerCompleted).isEmpty)
        #expect(machine.handle(.speechFinished).isEmpty)
        #expect(machine.state == .listening(partial: "hang on"))
    }

    @Test("the adopted listen endpoints into the next turn like any other")
    func adoptedListenRunsTheNextTurn() {
        var machine = speaking()
        _ = machine.handle(.bargeIn("hang on"))
        #expect(machine.handle(.endpointed("hang on what about Friday")) == [
            .stopListening, .runTurn("hang on what about Friday"),
        ])
    }

    @Test("leaving speech any other way closes the watch first")
    func otherExitsCloseTheWatch() {
        var drained = speaking()
        _ = drained.handle(.answerCompleted)
        #expect(drained.handle(.speechFinished) == [.stopBargeInWatch, .startListening(afterEchoGrace: true)])

        var clicked = speaking()
        #expect(clicked.handle(.interrupt) == [.stopSpeaking, .stopBargeInWatch, .startListening(afterEchoGrace: true)])

        var paused = speaking()
        #expect(paused.handle(.pause) == [.stopSpeaking, .stopBargeInWatch])

        var exited = speaking()
        #expect(exited.handle(.exit) == [.stopSpeaking, .stopListening, .stopBargeInWatch])
    }

    @Test("a barge-in outside speech is stale")
    func bargeInOutsideSpeechIsStale() {
        var machine = VoiceLoopMachine(bargeIn: true)
        #expect(machine.handle(.bargeIn("hello there")).isEmpty)
        _ = machine.handle(.begin)
        #expect(machine.handle(.bargeIn("hello there")).isEmpty)
        #expect(machine.state == .listening(partial: ""))
    }

    @Test("off by default: no watch commands, and a barge-in event does nothing")
    func offByDefault() {
        var machine = VoiceLoopMachine()
        _ = machine.handle(.begin)
        _ = machine.handle(.endpointed("q"))
        #expect(machine.handle(.answerChunk("One.")) == [.speak("One.")])
        #expect(machine.handle(.bargeIn("hang on")).isEmpty)
        #expect(machine.state == .speaking(answer: "One."))
    }
}
