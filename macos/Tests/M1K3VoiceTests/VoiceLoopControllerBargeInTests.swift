import Foundation
import M1K3Voice
import Testing

/// Spoken barge-in through the driver (#640), with closure fakes: while M1K3 speaks
/// a watch listen runs, `BargeInPolicy` judges what it hears against the answer, and
/// a yes stops the speech and turns the watch into the next question's listen.
@MainActor
struct VoiceLoopControllerBargeInTests {
    @MainActor
    final class Harness {
        var listenStarts = 0
        var watchStarts = 0
        var stopListens = 0
        var turns: [String] = []
        var spoken: [String] = []
        var stopSpeaks = 0
        var echoLive = true
        var answer = "The hydraulic seal on the conveyor failed under load."
        var continuation: AsyncStream<TranscriptSegment>.Continuation?

        func dependencies(watches: Bool = true) -> VoiceLoopController.Dependencies {
            let watch: @MainActor () throws -> AsyncStream<TranscriptSegment>? = {
                self.watchStarts += 1
                return AsyncStream { self.continuation = $0 }
            }
            return VoiceLoopController.Dependencies(
                startListening: {
                    self.listenStarts += 1
                    return AsyncStream { self.continuation = $0 }
                },
                stopListening: {
                    self.stopListens += 1
                    self.continuation?.finish()
                    self.continuation = nil
                },
                runTurn: { question in
                    self.turns.append(question)
                    return .success(self.answer)
                },
                speak: { self.spoken.append($0) },
                stopSpeaking: { self.stopSpeaks += 1 },
                startBargeInWatch: watches ? watch : nil,
                echoCancellationLive: { self.echoLive }
            )
        }
    }

    private func makeController(_ harness: Harness, watches: Bool = true) -> VoiceLoopController {
        // Long silences: these tests drive the recogniser's finality, never the silence endpoint.
        VoiceLoopController(
            dependencies: harness.dependencies(watches: watches),
            silence: .seconds(30),
            holdSilence: .seconds(30),
            echoGrace: .zero,
            endpointTick: .milliseconds(10)
        )
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0 ..< 200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Ask one question and wait until M1K3 is speaking with the watch open.
    private func speaking(_ harness: Harness, _ controller: VoiceLoopController) async {
        controller.begin()
        await waitUntil { harness.continuation != nil }
        harness.continuation?.yield(TranscriptSegment(text: "what broke", isFinal: true))
        harness.continuation?.finish()
        await waitUntil { harness.watchStarts == 1 && harness.continuation != nil }
    }

    @Test("the watch hears the user over M1K3: speech stops and the words become the next question")
    func userCutsIn() async {
        let harness = Harness()
        let controller = makeController(harness)
        await speaking(harness, controller)
        #expect(controller.state == .speaking(answer: harness.answer))

        harness.continuation?.yield(TranscriptSegment(text: "hang on what", isFinal: false))
        harness.continuation?.yield(TranscriptSegment(text: "hang on what about Friday", isFinal: false))
        await waitUntil { harness.stopSpeaks == 1 }
        #expect(controller.state == .listening(partial: "hang on what about Friday"))

        harness.continuation?.yield(TranscriptSegment(text: "hang on what about Friday", isFinal: true))
        harness.continuation?.finish()
        await waitUntil { harness.turns.count == 2 }
        #expect(harness.turns == ["what broke", "hang on what about Friday"])
        // The watch was adopted, not restarted: no extra listen opened for the second question.
        #expect(harness.listenStarts == 1)
    }

    @Test("echo of the answer leaking into the watch never interrupts")
    func echoDoesNotInterrupt() async {
        let harness = Harness()
        let controller = makeController(harness)
        await speaking(harness, controller)

        harness.continuation?.yield(TranscriptSegment(text: "the conveyor failed under load", isFinal: false))
        await waitUntil { controller.state != .speaking(answer: harness.answer) }
        #expect(controller.state == .speaking(answer: harness.answer))
        #expect(harness.stopSpeaks == 0)
    }

    @Test("echo heard around the user is dropped from their question, through to the turn")
    func echoAroundTheUserIsDropped() async {
        let harness = Harness()
        let controller = makeController(harness)
        await speaking(harness, controller)

        harness.continuation?.yield(TranscriptSegment(text: "the conveyor failed", isFinal: false))
        harness.continuation?.yield(TranscriptSegment(text: "the conveyor failed hang on", isFinal: false))
        harness.continuation?.yield(TranscriptSegment(text: "the conveyor failed hang on wait", isFinal: false))
        await waitUntil { harness.stopSpeaks == 1 }
        #expect(controller.state == .listening(partial: "hang on wait"))

        harness.continuation?.yield(TranscriptSegment(
            text: "The conveyor failed. Hang on, wait. The hydraulic seal", isFinal: true
        ))
        harness.continuation?.finish()
        await waitUntil { harness.turns.count == 2 }
        #expect(harness.turns.last == "Hang on, wait.")
    }

    @Test("one partial is not enough: the user must still be heard in the next one")
    func oneFlickerDoesNotInterrupt() async {
        let harness = Harness()
        let controller = makeController(harness)
        await speaking(harness, controller)

        harness.continuation?.yield(TranscriptSegment(text: "hang on", isFinal: false))
        harness.continuation?.yield(TranscriptSegment(text: "the conveyor failed under load", isFinal: false))
        await waitUntil { controller.state != .speaking(answer: harness.answer) }
        #expect(controller.state == .speaking(answer: harness.answer))
        #expect(harness.stopSpeaks == 0)
    }

    @Test("a watch the recogniser closes mid-answer reopens, a bounded number of times")
    func watchReopensBounded() async {
        let harness = Harness()
        let controller = makeController(harness)
        await speaking(harness, controller)
        for expected in 2 ... 4 {
            harness.continuation?.finish()
            harness.continuation = nil
            await waitUntil { harness.watchStarts == expected && harness.continuation != nil }
            #expect(harness.watchStarts == expected)
        }
        harness.continuation?.finish()
        harness.continuation = nil
        await waitUntil { harness.watchStarts > 4 }
        #expect(harness.watchStarts == 4)
        #expect(controller.state == .speaking(answer: harness.answer))
    }

    @Test("without live echo cancellation the watch hears M1K3, so nothing it hears interrupts")
    func needsLiveEchoCancellation() async {
        let harness = Harness()
        harness.echoLive = false
        let controller = makeController(harness)
        await speaking(harness, controller)

        harness.continuation?.yield(TranscriptSegment(text: "hang on what about Friday", isFinal: false))
        await waitUntil { controller.state != .speaking(answer: harness.answer) }
        #expect(controller.state == .speaking(answer: harness.answer))
        #expect(harness.stopSpeaks == 0)
    }

    @Test("speech ending naturally closes the watch, then listens as before")
    func naturalEndClosesTheWatch() async {
        let harness = Harness()
        let controller = makeController(harness)
        await speaking(harness, controller)
        let stopsBefore = harness.stopListens

        controller.speechDidEnd()
        await waitUntil { harness.listenStarts == 2 }
        #expect(harness.stopListens == stopsBefore + 1)
        #expect(controller.state == .listening(partial: ""))
    }

    @Test("no watch dependency: the loop stays half-duplex, no mic while speaking")
    func noWatchStaysHalfDuplex() async {
        let harness = Harness()
        let controller = makeController(harness, watches: false)
        controller.begin()
        await waitUntil { harness.continuation != nil }
        harness.continuation?.yield(TranscriptSegment(text: "what broke", isFinal: true))
        harness.continuation?.finish()
        await waitUntil { !harness.spoken.isEmpty }
        #expect(controller.state == .speaking(answer: harness.answer))
        #expect(harness.watchStarts == 0)
        #expect(harness.continuation == nil)
    }
}
