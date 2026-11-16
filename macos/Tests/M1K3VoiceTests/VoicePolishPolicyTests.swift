//
//  VoicePolishPolicyTests.swift
//  M1K3VoiceTests
//
//  The polish pass's pure layer (VoicePolishPolicy, UtteranceRecorder, VoicePolisher): when the
//  accurate re-run replaces the live final, what it captures, and how a slow or failing pass
//  falls back. The Speech glue itself (AppleBufferTranscriber) is verify-by-launch + the eval.
//
//  Signed: Kev + claude-opus-5-5, 2026-11-16, Confidence 0.8, Prior: Unknown (new file).

import AVFoundation
import Foundation
@testable import M1K3Voice
import Testing

struct VoicePolishPolicyTests {
    private func audio(seconds: Double = 3, rate: Double = 16000, truncated: Bool = false) -> UtteranceAudio {
        UtteranceAudio(samples: [Float](repeating: 0.1, count: Int(seconds * rate)), sampleRate: rate, truncated: truncated)
    }

    @Test("off unless argv says yes: -voicePolishPass YES")
    func switchIsOffByDefault() {
        #expect(!VoicePolishPolicy.enabled(arguments: [:]))
        #expect(!VoicePolishPolicy.enabled(arguments: ["voicePolishPass": "NO"]))
        #expect(!VoicePolishPolicy.enabled(arguments: ["voicePolishPass": "maybe"]))
        #expect(!VoicePolishPolicy.enabled(arguments: ["voicePolishPass": 1]))
        for yes in ["YES", "yes", "1", "true", "on"] {
            #expect(VoicePolishPolicy.enabled(arguments: ["voicePolishPass": yes]))
        }
    }

    @Test("an utterance too long for the budget is skipped, one under the limit is not")
    func tooLongSkipped() {
        let limit = VoicePolishPolicy.maxPolishSeconds
        #expect(VoicePolishPolicy.skipReason(audio: audio(seconds: limit + 1)) == .tooLong)
        #expect(VoicePolishPolicy.skipReason(audio: audio(seconds: limit - 1)) == nil)
    }

    @Test("capture keeps enough for the longest polishable utterance, and truncates beyond it")
    func captureCoversPolishLimit() throws {
        let recorder = UtteranceRecorder()
        recorder.isEnabled = true
        recorder.beginListen()
        let samples = [Float](repeating: 0.1, count: Int(VoicePolishPolicy.maxPolishSeconds * 16000))
        samples.withUnsafeBufferPointer { recorder.append($0, sampleRate: 16000) }
        let kept = try #require(recorder.take())
        #expect(!kept.truncated)
        #expect(VoicePolishPolicy.skipReason(audio: kept) == nil)
    }

    @Test("no audio, truncated audio and a blip are not worth a pass")
    func preflight() {
        #expect(VoicePolishPolicy.skipReason(audio: nil) == .noAudio)
        #expect(VoicePolishPolicy.skipReason(audio: audio(truncated: true)) == .truncated)
        #expect(VoicePolishPolicy.skipReason(audio: audio(seconds: 0.1)) == .tooShort)
        #expect(VoicePolishPolicy.skipReason(audio: audio()) == nil)
    }

    @Test("a good polished text replaces the live one")
    func replaces() {
        let live = "You're my curry keeping, are you well?"
        let polished = "How're you keeping, are you well?"
        #expect(VoicePolishPolicy.decide(live: live, result: .text(polished)) == .use(polished))
    }

    @Test("empty, failed or timed-out passes keep the live text")
    func fallbacks() {
        let live = "what is the weather like"
        #expect(VoicePolishPolicy.decide(live: live, result: .text("  ")) == .keep(.empty))
        #expect(VoicePolishPolicy.decide(live: live, result: .failed) == .keep(.failed))
        #expect(VoicePolishPolicy.decide(live: live, result: .timedOut) == .keep(.timedOut))
    }

    @Test("a polished text that lost or grew far more words than the live one is not trusted")
    func implausible() {
        let live = "tell me about the walk up Carrauntoohil on Sunday"
        #expect(VoicePolishPolicy.decide(live: live, result: .text("tell me")) == .keep(.implausible))
        let long = Array(repeating: "word", count: 40).joined(separator: " ")
        #expect(VoicePolishPolicy.decide(live: live, result: .text(long)) == .keep(.implausible))
        // Short utterances have no ratio to speak of: one word either way is normal.
        #expect(VoicePolishPolicy.decide(live: "hello", result: .text("Hello there")) == .use("Hello there"))
    }

    @Test("a short live text takes a polished text of one word up to three more, and no more")
    func shortLiveBounds() {
        #expect(VoicePolishPolicy.decide(live: "set a timer", result: .text("Set a timer.")) == .use("Set a timer."))
        // Longer by three words (live + 3): allowed.
        #expect(VoicePolishPolicy.decide(live: "set a timer", result: .text("set a timer for ten minutes"))
            == .use("set a timer for ten minutes"))
        // Same words plus a TV show's worth: refused.
        #expect(VoicePolishPolicy.decide(live: "set a timer", result: .text("set a timer for ten minutes please now"))
            == .keep(.implausible))
        // One word of noise where a command stood.
        #expect(VoicePolishPolicy.decide(live: "set a timer", result: .text("Mm")) == .keep(.implausible))
        #expect(VoicePolishPolicy.decide(live: "stop", result: .text("Mm")) == .keep(.implausible))
    }

    @Test("similar length but different words is not the same speech")
    func differentWords() {
        #expect(VoicePolishPolicy.decide(live: "set a timer", result: .text("play some music"))
            == .keep(.implausible))
        #expect(VoicePolishPolicy.decide(
            live: "what is the weather like in Cork today",
            result: .text("tell me a story about dragons please")
        ) == .keep(.implausible))
    }

    @Test("a real fix that shares at least two fifths of the words goes through, at any length")
    func similarEnoughPasses() {
        // Kev's own example: 4 of the 7 live words survive.
        #expect(VoicePolishPolicy.decide(
            live: "You're my curry keeping, are you well?", result: .text("How're you keeping, are you well?")
        ) == .use("How're you keeping, are you well?"))
        // Case, punctuation and apostrophes do not count as differences.
        #expect(VoicePolishPolicy.decide(live: "whats the time", result: .text("What's the time?"))
            == .use("What's the time?"))
        // Two of three live words survive; the third was the mishearing.
        #expect(VoicePolishPolicy.decide(live: "call my mother", result: .text("Call my mom"))
            == .use("Call my mom"))
    }

    @Test("a repeated live word needs its own repeat in the polished text")
    func multisetCoverage() {
        #expect(VoicePolishPolicy.decide(live: "no no no no", result: .text("no and so on"))
            == .keep(.implausible))
    }

    @Test("an all-noise polished text goes through the same hygiene as the live one")
    func sanitised() {
        let live = "right then"
        #expect(VoicePolishPolicy.decide(live: live, result: .text("thank you")) == .keep(.empty))
        #expect(VoicePolishPolicy.decide(live: live, result: .text("right   then  ")) == .use("right then"))
    }
}

struct UtteranceRecorderTests {
    private func feed(_ recorder: UtteranceRecorder, seconds: Double, rate: Double = 16000) {
        let samples = [Float](repeating: 0.25, count: Int(seconds * rate))
        samples.withUnsafeBufferPointer { recorder.append($0, sampleRate: rate) }
    }

    @Test("disabled, it keeps nothing")
    func disabled() {
        let recorder = UtteranceRecorder()
        feed(recorder, seconds: 1)
        #expect(recorder.take() == nil)
    }

    @Test("enabled, take returns what was fed and then starts over")
    func takeResets() throws {
        let recorder = UtteranceRecorder()
        recorder.isEnabled = true
        recorder.beginListen()
        feed(recorder, seconds: 1)
        feed(recorder, seconds: 0.5)
        let first = try #require(recorder.take())
        #expect(first.samples.count == 24000)
        #expect(first.sampleRate == 16000)
        #expect(!first.truncated)
        #expect(recorder.take() == nil)
    }

    @Test("memory is bounded: past the cap the rest is dropped and the audio says it is truncated")
    func capped() throws {
        let recorder = UtteranceRecorder(maxSeconds: 2)
        recorder.isEnabled = true
        recorder.beginListen()
        for _ in 0 ..< 5 {
            feed(recorder, seconds: 1)
        }
        let audio = try #require(recorder.take())
        #expect(audio.samples.count == 32000)
        #expect(audio.truncated)
    }

    @Test("a sample-rate change mid-listen marks the audio unusable rather than splicing two rates")
    func rateChange() throws {
        let recorder = UtteranceRecorder()
        recorder.isEnabled = true
        recorder.beginListen()
        feed(recorder, seconds: 1, rate: 48000)
        feed(recorder, seconds: 1, rate: 16000)
        #expect(try #require(recorder.take()).truncated)
    }

    @Test("reset forgets the last listen; turning capture off forgets it too")
    func resetAndOff() {
        let recorder = UtteranceRecorder()
        recorder.isEnabled = true
        recorder.beginListen()
        feed(recorder, seconds: 1)
        recorder.reset()
        #expect(recorder.take() == nil)
        feed(recorder, seconds: 1)
        recorder.isEnabled = false
        #expect(recorder.take() == nil)
    }

    @Test("capture switched on mid-listen records nothing until the next listen begins")
    func enableMidListen() throws {
        let recorder = UtteranceRecorder()
        recorder.isEnabled = true // the shell flips it on while a listen is already running
        feed(recorder, seconds: 1) // no beginListen yet: the front of this utterance is missing
        #expect(recorder.take() == nil)
        recorder.beginListen()
        feed(recorder, seconds: 1)
        #expect(try #require(recorder.take()).samples.count == 16000)
    }

    @Test("a listen that must not be recorded (a barge-in watch) keeps nothing, and the next one records")
    func watchListenNotRecorded() {
        let recorder = UtteranceRecorder()
        recorder.isEnabled = true
        recorder.beginListen(recording: false)
        feed(recorder, seconds: 1)
        #expect(recorder.take() == nil)
        recorder.beginListen()
        feed(recorder, seconds: 1)
        #expect(recorder.take() != nil)
    }

    @Test("the whole cap is reserved up front, so the realtime tap never reallocates")
    func reservesUpFront() {
        let recorder = UtteranceRecorder(maxSeconds: 2)
        recorder.isEnabled = true
        recorder.beginListen()
        #expect(recorder.reservedCapacity >= 2 * 48000)
        feed(recorder, seconds: 1, rate: 48000)
        _ = recorder.take()
        #expect(recorder.reservedCapacity >= 2 * 48000)
        recorder.isEnabled = false
        #expect(recorder.reservedCapacity == 0)
    }

    private func pcm(
        channels: AVAudioChannelCount, frames: Int, interleaved: Bool = false,
        format common: AVAudioCommonFormat = .pcmFormatFloat32, fill: (Int, Int) -> Float
    ) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(
            commonFormat: common, sampleRate: 16000, channels: channels, interleaved: interleaved
        ))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        if let data = buffer.floatChannelData, !interleaved {
            for channel in 0 ..< Int(channels) {
                for frame in 0 ..< frames {
                    data[channel][frame] = fill(channel, frame)
                }
            }
        }
        return buffer
    }

    @Test("a multi-channel float buffer is averaged to mono, not read from channel 0 alone")
    func averagesChannels() throws {
        let recorder = UtteranceRecorder()
        recorder.isEnabled = true
        recorder.beginListen()
        try recorder.append(pcm(channels: 2, frames: 4) { channel, _ in channel == 0 ? 0.2 : 0.6 })
        let audio = try #require(recorder.take())
        #expect(audio.samples.count == 4)
        #expect(audio.samples.allSatisfy { abs($0 - 0.4) < 1e-6 })
        #expect(!audio.truncated)
    }

    @Test("an interleaved or non-float buffer leaves no silent hole: the audio reads truncated")
    func unreadableBufferMarksTruncated() throws {
        for buffer in try [
            pcm(channels: 2, frames: 4, interleaved: true) { _, _ in 0 },
            pcm(channels: 1, frames: 4, format: .pcmFormatInt16) { _, _ in 0 },
        ] {
            let recorder = UtteranceRecorder()
            recorder.isEnabled = true
            recorder.beginListen()
            feed(recorder, seconds: 0.5)
            recorder.append(buffer)
            feed(recorder, seconds: 0.5)
            #expect(try #require(recorder.take()).truncated)
        }
    }

    @Test("the padded copy ends on a full second of silence and leaves the original alone")
    func padding() {
        let audio = UtteranceAudio(samples: [0.5, 0.5], sampleRate: 100, truncated: false)
        let padded = audio.padded(trailingSilenceSeconds: 1)
        #expect(padded.count == 102)
        #expect(padded.prefix(2).allSatisfy { $0 == 0.5 })
        #expect(padded.dropFirst(2).allSatisfy { $0 == 0 })
        #expect(audio.samples.count == 2)
    }
}

struct VoicePolisherTests {
    private let audio = UtteranceAudio(
        samples: [Float](repeating: 0.1, count: 48000), sampleRate: 16000, truncated: false
    )

    private func polisher(
        enabled: Bool = true, budget: Double = 3600, pass: @escaping VoicePolisher.Pass
    ) -> VoicePolisher {
        VoicePolisher(enabled: enabled, budgetSeconds: budget, pass: pass)
    }

    @Test("disabled, the live text goes through untouched and the pass never runs")
    func disabledNeverRuns() async {
        let polisher = polisher(enabled: false) { _ in
            Issue.record("the pass ran while disabled")
            return "nope"
        }
        let outcome = await polisher.run(live: "hello there", audio: audio)
        #expect(outcome.text == "hello there")
        #expect(outcome.reason == .off)
        #expect(!outcome.changed)
    }

    @Test("a polished text wins and the outcome says it changed")
    func polishedWins() async {
        let polisher = polisher { _ in "How're you keeping, are you well?" }
        let outcome = await polisher.run(live: "You're my curry keeping, are you well?", audio: audio)
        #expect(outcome.text == "How're you keeping, are you well?")
        #expect(outcome.changed)
        #expect(outcome.reason == nil)
    }

    @Test("the same words again is not a change")
    func sameWords() async {
        let polisher = polisher { _ in "what time is it" }
        let outcome = await polisher.run(live: "what time is it", audio: audio)
        #expect(outcome.text == "what time is it")
        #expect(!outcome.changed)
    }

    @Test("a pass that throws keeps the live text")
    func throwing() async {
        struct Boom: Error {}
        let polisher = polisher { _ in throw Boom() }
        let outcome = await polisher.run(live: "what time is it", audio: audio)
        #expect(outcome.text == "what time is it")
        #expect(outcome.reason == .failed)
    }

    @Test("a pass that outlives its budget is abandoned and the live text stands")
    func timesOut() async {
        let polisher = polisher(budget: 0.05) { _ in
            try await Task.sleep(for: .seconds(3600)) // only cancellation ends this
            return "too late"
        }
        let outcome = await polisher.run(live: "what time is it", audio: audio)
        #expect(outcome.text == "what time is it")
        #expect(outcome.reason == .timedOut)
    }

    @Test("a pass that ignores cancellation still cannot stall the turn")
    func stubbornPass() async {
        let release = AsyncGate()
        let polisher = polisher(budget: 0.05) { _ in
            await release.wait() // does not honour cancellation
            return "too late"
        }
        let outcome = await polisher.run(live: "what time is it", audio: audio)
        #expect(outcome.reason == .timedOut)
        await release.open()
    }

    @Test("cancelling the turn cancels the pass and returns at once, live text kept")
    func cancelledTurn() async {
        let started = AsyncGate()
        let cancelled = AsyncGate()
        let polisher = polisher { _ in
            await started.open()
            await withTaskCancellationHandler {
                await AsyncGate().wait() // never opens; only the handler below ends the test
            } onCancel: {
                Task { await cancelled.open() }
            }
            return "too late"
        }
        let audio = audio
        let turn = Task { await polisher.run(live: "what time is it", audio: audio) }
        await started.wait()
        turn.cancel()
        let outcome = await turn.value
        #expect(outcome.text == "what time is it")
        #expect(outcome.reason == .failed)
        await cancelled.wait() // the pass itself was told to stop
    }

    @Test("a timeout cancels the abandoned pass")
    func timeoutCancelsPass() async {
        let cancelled = AsyncGate()
        let polisher = polisher(budget: 0.05) { _ in
            await withTaskCancellationHandler {
                await AsyncGate().wait()
            } onCancel: {
                Task { await cancelled.open() }
            }
            return "too late"
        }
        #expect(await polisher.run(live: "what time is it", audio: audio).reason == .timedOut)
        await cancelled.wait()
    }

    @Test("the first result runs the cleanup (timer and pass cancel) exactly once")
    func firstResultCleanup() async {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func bump() {
                lock.withLock { value += 1 }
            }

            var count: Int {
                lock.withLock { value }
            }
        }
        let counter = Counter()
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<VoicePolishPolicy.PassResult, Never>) in
            let first = FirstResult()
            first.install(continuation)
            first.onDelivered { counter.bump() }
            #expect(first.deliver(.text("a")))
            #expect(!first.deliver(.timedOut))
        }
        #expect(result == .text("a"))
        #expect(counter.count == 1)
        // A cleanup registered after delivery runs at once.
        let late = FirstResult()
        #expect(late.deliver(.failed))
        late.onDelivered { counter.bump() }
        #expect(counter.count == 2)
    }

    @Test("missing or truncated audio skips the pass entirely")
    func skips() async {
        let polisher = polisher { _ in
            Issue.record("the pass ran without usable audio")
            return "nope"
        }
        #expect(await polisher.run(live: "hello there", audio: nil).reason == .noAudio)
        let cut = UtteranceAudio(samples: audio.samples, sampleRate: 16000, truncated: true)
        #expect(await polisher.run(live: "hello there", audio: cut).reason == .truncated)
    }

    @Test("an empty live text is never polished into a turn")
    func emptyLive() async {
        let polisher = polisher { _ in "something" }
        let outcome = await polisher.run(live: "", audio: audio)
        #expect(outcome.text == "")
        #expect(outcome.reason == .noLiveText)
    }
}

/// Lets a test hold a non-cancellable child open until it chooses to release it.
private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters {
            waiter.resume()
        }
        waiters = []
    }
}
