//
//  RecognizerFinalityTests.swift
//  M1K3VoiceTests
//
//  Signed: Kev + claude-fable-5, 2026-08-15, Confidence 0.9 (pure contracts,
//  synthetic clocks/fakes — no real recognizer). Prior: Unknown.
//

import Foundation
import M1K3Voice
import os
import Testing

/// Pins the finality policy that takes the turn boundary back from the
/// recognizer. The 2026-08-15 finding: on Apple Speech, `isFinal` ended the
/// stream and the stream-end fired `.endpointed` unconditionally — so the
/// recognizer's own (short, untunable) silence window owned the turn, and the
/// entire cadence stack (silence/hold/learned floor/"please") only ever ran if
/// it happened to beat Apple to the punch. WhisperKit never had the problem: it
/// only finalizes when WE stop it. The policy makes that authority explicit and
/// consumer-chosen: voice-first keeps listening through recognizer finality
/// (restarting recognition under the same session), while chat dictation and
/// the MCP listen tool keep today's ends-the-listen behaviour.
struct RecognizerFinalityTests {
    @Test("keepsListening restarts only when the listen has captured text")
    func keepsListeningRestartsOnlyWithText() {
        // Nothing captured = nothing can be cut off; a silent listen ends
        // exactly as today so the empty-listen park still works.
        #expect(FinalityPolicy.keepsListening.shouldRestart(hasCapturedText: true))
        #expect(!FinalityPolicy.keepsListening.shouldRestart(hasCapturedText: false))
    }

    @Test("endsListen never restarts")
    func endsListenNeverRestarts() {
        #expect(!FinalityPolicy.endsListen.shouldRestart(hasCapturedText: true))
        #expect(!FinalityPolicy.endsListen.shouldRestart(hasCapturedText: false))
    }

    @Test("providers without a policy-aware start fall back to plain startListening")
    func defaultStartForwardsIgnoringPolicy() throws {
        let provider = CountingProvider()
        _ = try provider.startListening(finality: .keepsListening)
        #expect(provider.startCalls.withLock { $0 } == 1)
    }

    // MARK: - Error classification (review fold, #129)

    @Test("only Apple's benign no-speech error counts as finality worth restarting through")
    func benignNoSpeechClassification() {
        // The restart exists for SILENCE (isFinal, or the no-speech error the
        // recognizer throws instead of finalizing). A revoked authorization, a
        // broken model, or a bad format must NOT be masked as segment-boundary
        // churn — those fall through to today's end-the-listen behaviour, with
        // the error finally logged (the review's point: the fix that exists to
        // make turn-endings visible was itself swallowing the real reason).
        let noSpeech = NSError(domain: "kAFAssistantErrorDomain", code: 1110)
        #expect(RecognizerFinality.isBenignNoSpeech(noSpeech))

        let sameDomainOtherCode = NSError(domain: "kAFAssistantErrorDomain", code: 203)
        #expect(!RecognizerFinality.isBenignNoSpeech(sameDomainOtherCode))

        let otherDomain = NSError(domain: "SFSpeechErrorDomain", code: 1110)
        #expect(!RecognizerFinality.isBenignNoSpeech(otherDomain))

        #expect(!RecognizerFinality.isBenignNoSpeech(CancellationError()))
    }
}

/// Minimal conforming fake: only the required surface, so it exercises the
/// protocol extension's default `startListening(finality:)`.
private final class CountingProvider: TranscriptionProvider, @unchecked Sendable {
    let name = "Counting"
    let isAvailable = true
    let startCalls = OSAllocatedUnfairLock(initialState: 0)

    func startListening() throws -> AsyncStream<TranscriptSegment> {
        startCalls.withLock { $0 += 1 }
        return AsyncStream { $0.finish() }
    }

    func stopListening() {}
}
