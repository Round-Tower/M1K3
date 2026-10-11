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
//  Review: Kev + claude-opus-5.5, 2026-10-11 (pre-push review fold) — K7: a bare WakeSetupFlow() is the four-card wait deck, no kit. Confidence 0.9.

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

    @Test("K7: a bare WakeSetupFlow() is the wait deck: four cards, no kit, and an untouched one still auto-advances")
    func bareFlowIsTheWaitDeck() {
        var flow = WakeSetupFlow()
        #expect(flow.cards == WakeSetupCard.waitDeck)
        #expect(flow.cards.count == 4)
        #expect(!flow.cards.contains(.kit))
        #expect(WakeSetupFlow(cards: []).cards == WakeSetupCard.waitDeck, "an empty deck falls back to the wait deck, not the kit")
        flow.markBrainReady()
        #expect(flow.completion == .autoComplete)
        // The no-wait deck asks for the kit by name.
        #expect(WakeSetupFlow(cards: WakeSetupCard.allCases, brainAlreadyReady: true).cards.last == .kit)
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
