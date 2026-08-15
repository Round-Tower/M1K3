import Foundation
import M1K3Voice
import Testing

/// Pins `SilenceEndpointer.decision(at:)` — the reason-carrying twin of
/// `shouldEndpoint(at:)`. The 2026-08-15 log read found a whole session with
/// exactly ONE endpointing breadcrumb: the decision itself (which branch fired,
/// how long the idle gap was) had never been observable, so every "it cut me
/// off" report started from zero. The decision is now a first-class value the
/// controller logs; these tests pin that each branch names itself honestly and
/// that `shouldEndpoint` stays exactly `decision != nil`.
struct EndpointDecisionTests {
    private let start = ContinuousClock.now

    @Test("no decision while the partial keeps growing")
    func growingPartialHasNoDecision() {
        var endpointer = SilenceEndpointer(silence: .seconds(1.8))
        endpointer.ingest(partial: "hello", at: start)
        endpointer.ingest(partial: "hello there", at: start.advanced(by: .seconds(1.5)))
        #expect(endpointer.decision(at: start.advanced(by: .seconds(2.0))) == nil)
    }

    @Test("a stable complete thought decides with the completeThought reason")
    func completeThoughtReason() {
        var endpointer = SilenceEndpointer(silence: .seconds(1.8), holdSilence: .seconds(3.0))
        endpointer.ingest(partial: "what is in the doc", at: start)
        let decision = endpointer.decision(at: start.advanced(by: .seconds(2.0)))
        #expect(decision?.reason == .completeThought)
        #expect(decision?.idle == .seconds(2.0))
        #expect(decision?.required == .seconds(1.8))
    }

    @Test("a trailed-off partial decides with the midThoughtHold reason and the hold threshold")
    func midThoughtHoldReason() {
        var endpointer = SilenceEndpointer(silence: .seconds(1.5), holdSilence: .seconds(3.0))
        endpointer.ingest(partial: "tell me about the", at: start)
        #expect(endpointer.decision(at: start.advanced(by: .seconds(2.0))) == nil)
        let decision = endpointer.decision(at: start.advanced(by: .seconds(3.0)))
        #expect(decision?.reason == .midThoughtHold)
        #expect(decision?.required == .seconds(3.0))
    }

    @Test("a trailing please decides with the politeWord reason on the short window")
    func politeWordReason() {
        var endpointer = SilenceEndpointer(
            silence: .seconds(2.5), holdSilence: .seconds(5.0), politeSilence: .seconds(1.0)
        )
        endpointer.ingest(partial: "tell me a story please", at: start)
        let decision = endpointer.decision(at: start.advanced(by: .seconds(1.1)))
        #expect(decision?.reason == .politeWord)
        #expect(decision?.required == .seconds(1.0))
    }

    @Test("the anti-hang backstop decides with the maxWait reason")
    func maxWaitReason() {
        var endpointer = SilenceEndpointer(
            silence: .seconds(1.5), holdSilence: .seconds(30), maxWait: .seconds(5)
        )
        // A dangling partial would normally wait the 30s hold — maxWait cuts in.
        endpointer.ingest(partial: "tell me about the", at: start)
        let decision = endpointer.decision(at: start.advanced(by: .seconds(6.0)))
        #expect(decision?.reason == .maxWait)
    }

    @Test("the learned cadence floor is carried in required, reason stays completeThought")
    func learnedFloorRaisesRequired() {
        var endpointer = SilenceEndpointer(
            silence: .seconds(2.0), holdSilence: .seconds(4.5),
            cadenceMargin: .seconds(0.75), cadenceCeiling: .seconds(6.0)
        )
        // Teach a 3s rhythm: later waits are 3.75s, and the log should say so.
        endpointer.ingest(partial: "the thing", at: start)
        endpointer.ingest(partial: "the thing and more", at: start.advanced(by: .seconds(3.0)))
        #expect(endpointer.decision(at: start.advanced(by: .seconds(6.0))) == nil)
        let decision = endpointer.decision(at: start.advanced(by: .seconds(6.8)))
        #expect(decision?.reason == .completeThought)
        #expect(decision?.required == .seconds(3.75))
    }

    @Test("shouldEndpoint is exactly decision != nil")
    func shouldEndpointMatchesDecision() {
        var endpointer = SilenceEndpointer(silence: .seconds(1.8))
        endpointer.ingest(partial: "hello there", at: start)
        for offset in [1.0, 1.7, 1.8, 2.5, 10.0] {
            let instant = start.advanced(by: .seconds(offset))
            #expect(endpointer.shouldEndpoint(at: instant)
                == (endpointer.decision(at: instant) != nil))
        }
    }

    @Test("the log line carries the reason and both durations in seconds")
    func logLineReadsForHumans() {
        let decision = EndpointDecision(
            reason: .completeThought, idle: .seconds(2.6), required: .seconds(2.5)
        )
        #expect(decision.logLine == "voice endpoint: complete thought · idle 2.6s · required 2.5s")
    }

    @Test("the log line names the polite branch")
    func logLineNamesPolite() {
        let decision = EndpointDecision(
            reason: .politeWord, idle: .seconds(1.2), required: .seconds(1.2)
        )
        #expect(decision.logLine == "voice endpoint: polite word · idle 1.2s · required 1.2s")
    }
}
