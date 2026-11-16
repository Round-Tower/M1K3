//
//  VoicePolishPolicyTests.swift
//  M1K3VoiceTests
//
//  The polish pass's pure layer (VoicePolishPolicy, UtteranceRecorder, VoicePolisher): when the
//  accurate re-run replaces the live final, what it captures, and how a slow or failing pass
//  falls back. The Speech glue itself (AppleBufferTranscriber) is verify-by-launch + the eval.
//
//  Signed: Kev + claude-opus-5-5, 2026-11-16, Confidence 0.8, Prior: Unknown (new file).

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

    @Test("the pass is given up on inside a second and a half, and pads a full second of silence")
    func constants() {
        #expect(VoicePolishPolicy.budgetSeconds <= 1.5)
        #expect(VoicePolishPolicy.trailingSilenceSeconds >= 1.0)
        #expect(VoicePolishPolicy.maxCaptureSeconds == 60)
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
        feed(recorder, seconds: 1, rate: 48000)
        feed(recorder, seconds: 1, rate: 16000)
        #expect(try #require(recorder.take()).truncated)
    }

    @Test("reset forgets the last listen; turning capture off forgets it too")
    func resetAndOff() {
        let recorder = UtteranceRecorder()
        recorder.isEnabled = true
        feed(recorder, seconds: 1)
        recorder.reset()
        #expect(recorder.take() == nil)
        feed(recorder, seconds: 1)
        recorder.isEnabled = false
        #expect(recorder.take() == nil)
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
