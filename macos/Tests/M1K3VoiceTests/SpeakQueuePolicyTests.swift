//
//  SpeakQueuePolicyTests.swift
//  M1K3VoiceTests
//
//  Table-driven pins for the visitor-speak admission decision (#283).
//

@testable import M1K3Voice
import Testing

struct SpeakQueuePolicyTests {
    @Test("nothing in flight plays immediately")
    func playsNowWhenIdle() {
        #expect(SpeakQueuePolicy.decide(isSpeaking: false, queued: 0, cap: 3) == .playNow)
    }

    @Test("not speaking always plays now, even if queued is inconsistently non-zero")
    func idleAlwaysPlaysNowRegardlessOfQueued() {
        // Defensive pin: `isSpeaking` is the authority here, not `queued` — a
        // caller only ever passes a non-zero queued alongside isSpeaking:true
        // in practice, but the policy must not misbehave if that invariant slips.
        #expect(SpeakQueuePolicy.decide(isSpeaking: false, queued: 2, cap: 3) == .playNow)
    }

    @Test("something in flight with room in the queue takes the next position")
    func enqueuesWithPosition() {
        #expect(SpeakQueuePolicy.decide(isSpeaking: true, queued: 0, cap: 3) == .enqueue(position: 1))
        #expect(SpeakQueuePolicy.decide(isSpeaking: true, queued: 1, cap: 3) == .enqueue(position: 2))
        #expect(SpeakQueuePolicy.decide(isSpeaking: true, queued: 2, cap: 3) == .enqueue(position: 3))
    }

    @Test("a queue at capacity refuses rather than growing unbounded")
    func refusesAtCap() {
        #expect(SpeakQueuePolicy.decide(isSpeaking: true, queued: 3, cap: 3) == .refuse(queued: 3))
        #expect(SpeakQueuePolicy.decide(isSpeaking: true, queued: 5, cap: 3) == .refuse(queued: 5))
    }

    @Test("a zero cap refuses outright the moment anything is in flight")
    func zeroCapRefusesImmediately() {
        #expect(SpeakQueuePolicy.decide(isSpeaking: true, queued: 0, cap: 0) == .refuse(queued: 0))
    }

    @Test("the default cap is 3")
    func defaultCapIsThree() {
        #expect(SpeakQueuePolicy.decide(isSpeaking: true, queued: 2) == .enqueue(position: 3))
        #expect(SpeakQueuePolicy.decide(isSpeaking: true, queued: 3) == .refuse(queued: 3))
        #expect(SpeakQueuePolicy.defaultCap == 3)
    }
}
