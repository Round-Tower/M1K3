//
//  OnboardingTraceTests.swift
//  M1K3LogCoreTests
//
//  The re-run sheet's stopwatch (Kev, TestFlight 2026-10-11: "it was slow"): milliseconds since
//  the button tap, so the next build's log says where the time goes. Pure clock, injected "now".
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.85. Prior: none (new file).

@testable import M1K3LogCore
import Testing

struct OnboardingTraceTests {
    @Test("nothing is armed until a tap begins the trace")
    func unarmedHasNoElapsed() {
        let trace = OnboardingTrace()
        #expect(trace.elapsedMilliseconds(at: .now) == nil)
    }

    @Test("elapsed is whole milliseconds since begin, and end disarms")
    func elapsedAndEnd() {
        let trace = OnboardingTrace()
        let start = ContinuousClock.now
        trace.begin(at: start)
        #expect(trace.elapsedMilliseconds(at: start + .milliseconds(250)) == 250)
        trace.end()
        #expect(trace.elapsedMilliseconds(at: start + .milliseconds(300)) == nil)
    }

    @Test("a once-claim succeeds the first time only, and a new tap re-arms it")
    func onceClaim() {
        let trace = OnboardingTrace()
        trace.begin(at: .now)
        #expect(trace.claim("backdrop-ready"))
        #expect(!trace.claim("backdrop-ready"))
        trace.begin(at: .now)
        #expect(trace.claim("backdrop-ready"))
    }

    @Test("an unarmed trace refuses claims, so the live chat backdrop never logs")
    func unarmedRefusesClaims() {
        let trace = OnboardingTrace()
        #expect(!trace.claim("backdrop-ready"))
    }
}
