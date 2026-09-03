import Foundation
import M1K3Voice
import Testing

/// Pins EVERY transition of the voice-loop reducer. The machine is pure: events
/// in, commands out, no side effects — the driver executes commands. Stale
/// events (a speechFinished arriving after barge-in already moved us on, an
/// answerReady after exit) must produce NO commands.
struct VoiceLoopMachineTests {
    // MARK: - Begin / listen

    @Test("begin from idle starts listening without echo grace")
    func beginStartsListening() {
        var machine = VoiceLoopMachine()
        #expect(machine.state == .idle)
        let commands = machine.handle(.begin)
        #expect(commands == [.startListening(afterEchoGrace: false)])
        #expect(machine.state == .listening(partial: ""))
    }

    @Test("partials update the listening state, no commands")
    func partialsAccumulate() {
        var machine = VoiceLoopMachine()
        _ = machine.handle(.begin)
        let commands = machine.handle(.partial("hello wor"))
        #expect(commands.isEmpty)
        #expect(machine.state == .listening(partial: "hello wor"))
    }

    // MARK: - Endpoint → turn

    @Test("a non-empty endpoint stops the mic and runs the turn")
    func endpointRunsTurn() {
        var machine = VoiceLoopMachine()
        _ = machine.handle(.begin)
        let commands = machine.handle(.endpointed("what's the weather"))
        #expect(commands == [.stopListening, .runTurn("what's the weather")])
        #expect(machine.state == .awaitingAnswer(question: "what's the weather"))
    }

    @Test("an empty endpoint re-arms the mic once")
    func emptyEndpointRetries() {
        var machine = VoiceLoopMachine()
        _ = machine.handle(.begin)
        let commands = machine.handle(.endpointed("  "))
        #expect(commands == [.stopListening, .startListening(afterEchoGrace: false)])
        #expect(machine.state == .listening(partial: ""))
    }

    @Test("a second consecutive empty listen parks the mic in idle")
    func secondEmptyParks() {
        var machine = VoiceLoopMachine()
        _ = machine.handle(.begin)
        _ = machine.handle(.endpointed(""))
        let commands = machine.handle(.endpointed(""))
        #expect(commands == [.stopListening])
        #expect(machine.state == .idle)
    }

    @Test("a stale duplicate endpoint returns NO commands — the timing gate relies on exactly this")
    func staleEndpointReturnsNothing() {
        // Two independent endpoint sources exist (silence tick, recognizer
        // finality) and the machine is the arbiter of which one counts. The
        // controller's `recordTiming` gates its `.endpointed` handling on
        // `commands.isEmpty`, so this property — every REJECTED endpoint
        // returns an empty command list, every accepted arm a non-empty one
        // (pinned by the three tests above) — is load-bearing beyond the
        // machine itself. Widen with care.
        var awaiting = VoiceLoopMachine()
        _ = awaiting.handle(.begin)
        _ = awaiting.handle(.endpointed("what's the weather"))
        #expect(awaiting.handle(.endpointed("what's the weather")).isEmpty)

        var speaking = VoiceLoopMachine()
        _ = speaking.handle(.begin)
        _ = speaking.handle(.endpointed("hello"))
        _ = speaking.handle(.answerReady("hi"))
        #expect(speaking.handle(.endpointed("hello")).isEmpty)
    }

    @Test("a real utterance resets the empty-listen counter")
    func realUtteranceResetsCounter() {
        var machine = VoiceLoopMachine()
        _ = machine.handle(.begin)
        _ = machine.handle(.endpointed(""))
        _ = machine.handle(.endpointed("hello"))
        _ = machine.handle(.answerReady("hi"))
        _ = machine.handle(.speechFinished)
        // One more empty listen should retry (counter was reset), not park.
        let commands = machine.handle(.endpointed(""))
        #expect(commands == [.stopListening, .startListening(afterEchoGrace: false)])
        #expect(machine.state == .listening(partial: ""))
    }

    // MARK: - Answer → speak

    @Test("answerReady speaks the answer")
    func answerSpeaks() {
        var machine = VoiceLoopMachine()
        _ = machine.handle(.begin)
        _ = machine.handle(.endpointed("hello"))
        let commands = machine.handle(.answerReady("hi there"))
        #expect(commands == [.speak("hi there")])
        #expect(machine.state == .speaking(answer: "hi there"))
    }

    @Test("answerFailed lands in idle (the driver surfaces the error)")
    func answerFailedIdles() {
        var machine = VoiceLoopMachine()
        _ = machine.handle(.begin)
        _ = machine.handle(.endpointed("hello"))
        let commands = machine.handle(.answerFailed("model exploded"))
        #expect(commands.isEmpty)
        #expect(machine.state == .idle)
    }

    // MARK: - The hands-free beat: speech end → re-listen

    @Test("natural speech end auto-relistens WITH echo grace")
    func speechEndRelistens() {
        var machine = VoiceLoopMachine()
        _ = machine.handle(.begin)
        _ = machine.handle(.endpointed("hello"))
        _ = machine.handle(.answerReady("hi"))
        let commands = machine.handle(.speechFinished)
        #expect(commands == [.startListening(afterEchoGrace: true)])
        #expect(machine.state == .listening(partial: ""))
    }

    // MARK: - Barge-in

    @Test("interrupt while speaking stops speech and listens")
    func bargeIn() {
        var machine = VoiceLoopMachine()
        _ = machine.handle(.begin)
        _ = machine.handle(.endpointed("hello"))
        _ = machine.handle(.answerReady("hi"))
        let commands = machine.handle(.interrupt)
        #expect(commands == [.stopSpeaking, .startListening(afterEchoGrace: true)])
        #expect(machine.state == .listening(partial: ""))
    }

    @Test("the stale speechFinished after a barge-in is a no-op")
    func staleSpeechFinishedIgnored() {
        var machine = VoiceLoopMachine()
        _ = machine.handle(.begin)
        _ = machine.handle(.endpointed("hello"))
        _ = machine.handle(.answerReady("hi"))
        _ = machine.handle(.interrupt)
        // stop() fires onSpeakingEnded → arrives as speechFinished in .listening.
        let commands = machine.handle(.speechFinished)
        #expect(commands.isEmpty)
        #expect(machine.state == .listening(partial: ""))
    }

    @Test("interrupt while thinking is a no-op (v1)")
    func interruptWhileThinkingNoOp() {
        var machine = VoiceLoopMachine()
        _ = machine.handle(.begin)
        _ = machine.handle(.endpointed("hello"))
        let commands = machine.handle(.interrupt)
        #expect(commands.isEmpty)
        #expect(machine.state == .awaitingAnswer(question: "hello"))
    }

    // MARK: - Mute / park

    @Test("mute while listening parks the mic")
    func muteParks() {
        var machine = VoiceLoopMachine()
        _ = machine.handle(.begin)
        let commands = machine.handle(.mute)
        #expect(commands == [.stopListening])
        #expect(machine.state == .idle)
    }

    @Test("begin from parked idle re-arms the mic")
    func beginFromParked() {
        var machine = VoiceLoopMachine()
        _ = machine.handle(.begin)
        _ = machine.handle(.mute)
        let commands = machine.handle(.begin)
        #expect(commands == [.startListening(afterEchoGrace: false)])
        #expect(machine.state == .listening(partial: ""))
    }

    // MARK: - Exit

    @Test("exit from any state tears down both directions and is terminal")
    func exitTearsDown() {
        var listening = VoiceLoopMachine()
        _ = listening.handle(.begin)
        #expect(listening.handle(.exit) == [.stopSpeaking, .stopListening])
        #expect(listening.state == .ended)

        var speaking = VoiceLoopMachine()
        _ = speaking.handle(.begin)
        _ = speaking.handle(.endpointed("q"))
        _ = speaking.handle(.answerReady("a"))
        #expect(speaking.handle(.exit) == [.stopSpeaking, .stopListening])
        #expect(speaking.state == .ended)
    }

    @Test("after exit, a late answerReady is never spoken")
    func lateAnswerAfterExitIgnored() {
        var machine = VoiceLoopMachine()
        _ = machine.handle(.begin)
        _ = machine.handle(.endpointed("hello"))
        _ = machine.handle(.exit)
        let commands = machine.handle(.answerReady("too late"))
        #expect(commands.isEmpty)
        #expect(machine.state == .ended)
    }

    @Test("ended is terminal — even begin does nothing")
    func endedIsTerminal() {
        var machine = VoiceLoopMachine()
        _ = machine.handle(.exit)
        #expect(machine.handle(.begin).isEmpty)
        #expect(machine.state == .ended)
    }

    // MARK: - Misdelivered events

    @Test("events outside their state produce no commands")
    func wrongStateEventsIgnored() {
        var machine = VoiceLoopMachine()
        // idle: partials/endpoints/answers are stale noise.
        #expect(machine.handle(.partial("x")).isEmpty)
        #expect(machine.handle(.endpointed("x")).isEmpty)
        #expect(machine.handle(.answerReady("x")).isEmpty)
        #expect(machine.handle(.speechFinished).isEmpty)
        #expect(machine.state == .idle)

        // awaitingAnswer: a partial from a dead stream changes nothing.
        _ = machine.handle(.begin)
        _ = machine.handle(.endpointed("q"))
        #expect(machine.handle(.partial("ghost")).isEmpty)
        #expect(machine.state == .awaitingAnswer(question: "q"))
    }

    // MARK: - Sentence-streamed answers (2026-07-25: speak the first sentence

    // while the model is still generating — the loop previously sat silent for
    // the whole ~25s Big generation before speaking a word)

    private func machineAwaitingAnswer() -> VoiceLoopMachine {
        var machine = VoiceLoopMachine()
        _ = machine.handle(.begin)
        _ = machine.handle(.endpointed("q"))
        return machine
    }

    @Test("the first answer chunk starts speaking immediately")
    func firstChunkSpeaks() {
        var machine = machineAwaitingAnswer()
        let commands = machine.handle(.answerChunk("First sentence."))
        #expect(commands == [.speak("First sentence.")])
        #expect(machine.state == .speaking(answer: "First sentence."))
    }

    @Test("later chunks enqueue more speech and grow the answer")
    func laterChunksEnqueue() {
        var machine = machineAwaitingAnswer()
        _ = machine.handle(.answerChunk("One."))
        let commands = machine.handle(.answerChunk("Two."))
        #expect(commands == [.speak("Two.")])
        #expect(machine.state == .speaking(answer: "One. Two."))
    }

    @Test("re-listen waits for BOTH generation done and every chunk spoken")
    func relistenWaitsForDrainAndCompletion() {
        var machine = machineAwaitingAnswer()
        _ = machine.handle(.answerChunk("One."))
        _ = machine.handle(.answerChunk("Two."))
        // First utterance ends: one still queued, generation still running.
        #expect(machine.handle(.speechFinished).isEmpty)
        // Generation finishes while the second utterance still plays.
        #expect(machine.handle(.answerCompleted).isEmpty)
        #expect(machine.state == .speaking(answer: "One. Two."))
        // Final utterance ends → NOW re-listen with echo grace.
        let commands = machine.handle(.speechFinished)
        #expect(commands == [.startListening(afterEchoGrace: true)])
        #expect(machine.state == .listening(partial: ""))
    }

    @Test("completion arriving after the queue already drained re-listens at once")
    func completionAfterDrainRelistens() {
        var machine = machineAwaitingAnswer()
        _ = machine.handle(.answerChunk("Only sentence."))
        _ = machine.handle(.speechFinished) // spoken before generation ends
        #expect(machine.state == .speaking(answer: "Only sentence."))
        let commands = machine.handle(.answerCompleted)
        #expect(commands == [.startListening(afterEchoGrace: true)])
        #expect(machine.state == .listening(partial: ""))
    }

    @Test("a streamed turn that completes with zero chunks parks idle")
    func emptyStreamedAnswerParks() {
        var machine = machineAwaitingAnswer()
        let commands = machine.handle(.answerCompleted)
        #expect(commands.isEmpty)
        #expect(machine.state == .idle)
    }

    @Test("a failure mid-stream drains what's queued then re-listens")
    func midStreamFailureDrains() {
        var machine = machineAwaitingAnswer()
        _ = machine.handle(.answerChunk("Partial truth."))
        #expect(machine.handle(.answerFailed("model fell over")).isEmpty)
        // Still speaking the queued chunk; its end re-listens as usual.
        #expect(machine.state == .speaking(answer: "Partial truth."))
        let commands = machine.handle(.speechFinished)
        #expect(commands == [.startListening(afterEchoGrace: true)])
    }

    @Test("barge-in mid-stream drops every later chunk as stale")
    func bargeInDropsLateChunks() {
        var machine = machineAwaitingAnswer()
        _ = machine.handle(.answerChunk("One."))
        _ = machine.handle(.interrupt)
        #expect(machine.state == .listening(partial: ""))
        #expect(machine.handle(.answerChunk("Two.")).isEmpty)
        #expect(machine.handle(.answerCompleted).isEmpty)
        #expect(machine.state == .listening(partial: ""))
    }

    @Test("exit mid-stream drops later chunks — terminal stays terminal")
    func exitDropsLateChunks() {
        var machine = machineAwaitingAnswer()
        _ = machine.handle(.answerChunk("One."))
        _ = machine.handle(.exit)
        #expect(machine.handle(.answerChunk("Two.")).isEmpty)
        #expect(machine.handle(.answerCompleted).isEmpty)
        #expect(machine.state == .ended)
    }

    @Test("legacy answerReady still speaks once and re-listens on one speechFinished")
    func legacyAnswerReadyUnchanged() {
        var machine = machineAwaitingAnswer()
        _ = machine.handle(.answerReady("whole answer"))
        #expect(machine.state == .speaking(answer: "whole answer"))
        let commands = machine.handle(.speechFinished)
        #expect(commands == [.startListening(afterEchoGrace: true)])
        #expect(machine.state == .listening(partial: ""))
    }
}

// MARK: - Pause (audio interruptions: a call, headphones pulled)

extension VoiceLoopMachineTests {
    @Test("pause while listening parks the mic")
    func pauseWhileListeningParks() {
        var machine = VoiceLoopMachine()
        _ = machine.handle(.begin)
        let commands = machine.handle(.pause)
        #expect(commands == [.stopListening])
        #expect(machine.state == .idle)
    }

    @Test("pause while speaking stops speech, parks, and drops every later chunk")
    func pauseWhileSpeakingStopsAndDropsChunks() {
        var machine = VoiceLoopMachine()
        _ = machine.handle(.begin)
        _ = machine.handle(.endpointed("tell me a story"))
        _ = machine.handle(.answerChunk("Once upon a time."))
        let commands = machine.handle(.pause)
        #expect(commands == [.stopSpeaking])
        #expect(machine.state == .idle)
        // The generator is still running — its late chunks and completion are stale.
        #expect(machine.handle(.answerChunk("There was a fox.")).isEmpty)
        #expect(machine.handle(.answerCompleted).isEmpty)
        #expect(machine.handle(.speechFinished).isEmpty)
        #expect(machine.state == .idle)
    }

    @Test("pause while thinking parks; the answer lands in the transcript unspoken")
    func pauseWhileThinkingDropsTheAnswer() {
        var machine = VoiceLoopMachine()
        _ = machine.handle(.begin)
        _ = machine.handle(.endpointed("tell me a story"))
        let commands = machine.handle(.pause)
        #expect(commands.isEmpty)
        #expect(machine.state == .idle)
        #expect(machine.handle(.answerReady("Once upon a time.")).isEmpty)
        #expect(machine.state == .idle)
    }

    @Test("pause in idle is a no-op, and begin re-arms afterwards")
    func pauseInIdleIsNoOpAndBeginRearms() {
        var machine = VoiceLoopMachine()
        #expect(machine.handle(.pause).isEmpty)
        #expect(machine.state == .idle)
        #expect(machine.handle(.begin) == [.startListening(afterEchoGrace: false)])
    }

    @Test("pause after exit stays terminal")
    func pauseAfterExitIsNoOp() {
        var machine = VoiceLoopMachine()
        _ = machine.handle(.exit)
        #expect(machine.handle(.pause).isEmpty)
        #expect(machine.state == .ended)
    }
}

// MARK: - Patience (2026-09-03: conversational parking)

extension VoiceLoopMachineTests {
    @Test("the empty-listen budget is configurable — under 3, the second quiet listen re-arms and the third parks")
    func configurableEmptyListenBudget() {
        var machine = VoiceLoopMachine(maxEmptyListens: 3)
        _ = machine.handle(.begin)
        _ = machine.handle(.endpointed(""))
        let second = machine.handle(.endpointed(""))
        #expect(second == [.stopListening, .startListening(afterEchoGrace: false)])
        #expect(machine.state == .listening(partial: ""))
        let third = machine.handle(.endpointed(""))
        #expect(third == [.stopListening])
        #expect(machine.state == .idle)
    }

    @Test("the default budget is unchanged — two quiet listens still park")
    func defaultBudgetStaysTwo() {
        var machine = VoiceLoopMachine()
        _ = machine.handle(.begin)
        _ = machine.handle(.endpointed(""))
        #expect(machine.handle(.endpointed("")) == [.stopListening])
        #expect(machine.state == .idle)
    }
}
