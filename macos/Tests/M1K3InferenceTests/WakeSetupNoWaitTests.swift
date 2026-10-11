//
//  WakeSetupNoWaitTests.swift
//  M1K3InferenceTests
//
//  The setup deck with NO wait (Kev, TestFlight 2026-10-11: a re-run showed only the name
//  page; #540 defect 1). Readiness is a given there, so the do-nothing auto-advance would skip
//  the deck the instant it mounted: completion is the user's tap, every time. The wait paths
//  (WakeSetupTests) are untouched, and pinned again here beside the new rule.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.9. Prior: none (new file).

@testable import M1K3Inference
import Testing

struct WakeSetupNoWaitTests {
    @Test("a no-wait deck is ready from the first frame and never auto-completes")
    func untouchedNoWaitDeckInvites() {
        let flow = WakeSetupFlow(brainAlreadyReady: true)
        #expect(flow.brainReady)
        #expect(!flow.hasEngaged)
        #expect(flow.completion == .invite)
        #expect(flow.userDrivenCompletion)
    }

    @Test("an engaged no-wait deck still just invites")
    func engagedNoWaitDeckInvites() {
        var flow = WakeSetupFlow(brainAlreadyReady: true)
        flow.advance()
        flow.setNote("short answers, please")
        #expect(flow.completion == .invite)
    }

    @Test("the wait paths are unchanged: untouched auto-completes, engaged invites, unready waits")
    func waitPathsUnchanged() {
        var untouched = WakeSetupFlow()
        #expect(!untouched.userDrivenCompletion)
        #expect(untouched.completion == .keepWaiting)
        untouched.markBrainReady()
        #expect(untouched.completion == .autoComplete)

        var engaged = WakeSetupFlow()
        engaged.advance()
        engaged.markBrainReady()
        #expect(engaged.completion == .invite)
    }

    @Test("the explicit wait initialiser matches the default")
    func explicitWaitMatchesDefault() {
        #expect(WakeSetupFlow(brainAlreadyReady: false) == WakeSetupFlow())
    }

    @Test("the finish line says Done on a re-run and Start chatting on a first run")
    func finishLine() {
        #expect(WakeProgressCopy.finishLine(isRerun: true).contains("Done"))
        #expect(WakeProgressCopy.finishLine(isRerun: false).contains("Start chatting"))
    }
}
