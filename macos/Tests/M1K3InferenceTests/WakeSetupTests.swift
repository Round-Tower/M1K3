//
//  WakeSetupTests.swift
//  M1K3InferenceTests
//
//  The wake-setup carousel's whole personality lives here as pure, pinned
//  policy: the card flow (free back-and-forth while the brain downloads),
//  the no-yank completion rule, the deterministic progress copy (O4's
//  "personality progress" — a tested line-picker, no model involved), and
//  the avatar's alertness ramp. The invariant with teeth:
//    · THE DO-NOTHING USER GETS TODAY'S BEHAVIOUR — never touched a card →
//      ready auto-completes to chat exactly as before. Engagement is what
//      buys the gentler "tap when ready" invite (never a yank mid-card).
//
//  Signed: Kev + claude-fable-5, 2026-08-30, Confidence 0.9. Prior: none (new file).

@testable import M1K3Inference
import Testing

struct WakeSetupFlowTests {
    @Test("a fresh flow: first card, untouched, still waiting")
    func freshFlow() {
        let flow = WakeSetupFlow()
        #expect(flow.index == 0)
        #expect(flow.current == WakeSetupCard.allCases.first)
        #expect(!flow.hasEngaged)
        #expect(flow.completion == .keepWaiting)
    }

    @Test("advance and back walk the deck freely and clamp at both ends")
    func advanceAndBackClamp() {
        var flow = WakeSetupFlow()
        let last = WakeSetupCard.allCases.count - 1
        for _ in 0 ..< (last + 3) {
            flow.advance()
        }
        #expect(flow.index == last)
        for _ in 0 ..< (last + 3) {
            flow.back()
        }
        #expect(flow.index == 0)
    }

    @Test("moving through the deck counts as engagement; so does engage() in place")
    func movementEngages() {
        var moved = WakeSetupFlow()
        moved.advance()
        #expect(moved.hasEngaged)

        var touched = WakeSetupFlow()
        touched.engage()
        #expect(touched.hasEngaged)
        #expect(touched.index == 0)
    }

    @Test("the do-nothing user gets today's behaviour: ready + untouched → auto-complete")
    func doNothingAutoCompletes() {
        var flow = WakeSetupFlow()
        flow.markBrainReady()
        #expect(flow.completion == .autoComplete)
    }

    @Test("engaged + ready → invite, never a yank — regardless of which came first")
    func engagedReadyInvites() {
        var engagedFirst = WakeSetupFlow()
        engagedFirst.advance()
        engagedFirst.markBrainReady()
        #expect(engagedFirst.completion == .invite)

        var readyFirst = WakeSetupFlow()
        readyFirst.markBrainReady()
        readyFirst.engage()
        #expect(readyFirst.completion == .invite)
    }
}

struct WakeProgressCopyTests {
    @Test("every downloading line carries its honest percentage")
    func linesCarryPercent() {
        for fraction in [0.0, 0.2, 0.41, 0.6, 0.8, 0.97] {
            let pct = min(99, Int((fraction * 100).rounded()))
            #expect(WakeProgressCopy.line(fraction: fraction, name: nil).contains("\(pct)%"))
        }
    }

    @Test("the copy is deterministic and moves through distinct bands")
    func bandsAreDistinctAndDeterministic() {
        let early = WakeProgressCopy.line(fraction: 0.05, name: nil)
        let mid = WakeProgressCopy.line(fraction: 0.5, name: nil)
        let late = WakeProgressCopy.line(fraction: 0.95, name: nil)
        #expect(early != mid)
        #expect(mid != late)
        #expect(WakeProgressCopy.line(fraction: 0.5, name: nil) == mid)
    }

    @Test("the home stretch greets you by name when it knows one")
    func homeStretchUsesName() {
        #expect(WakeProgressCopy.line(fraction: 0.95, name: "Kev").contains("Kev"))
        #expect(!WakeProgressCopy.line(fraction: 0.95, name: nil).contains("Kev"))
        // The name never appears before the home stretch — earlier bands are
        // about the machine, not the person.
        #expect(!WakeProgressCopy.line(fraction: 0.3, name: "Kev").contains("Kev"))
    }

    @Test("a runaway fraction never claims 100% — the ready line owns that moment")
    func percentCapsAt99() {
        #expect(WakeProgressCopy.line(fraction: 1.0, name: nil).contains("99%"))
        #expect(WakeProgressCopy.line(fraction: 1.7, name: nil).contains("99%"))
    }

    @Test("the AFM warming wait cycles deterministic lines and wraps")
    func warmingLinesCycle() {
        let count = 4
        var seen = Set<String>()
        for tick in 0 ..< count {
            seen.insert(WakeProgressCopy.warmingLine(tick: tick))
        }
        #expect(seen.count > 1)
        #expect(WakeProgressCopy.warmingLine(tick: 0) == WakeProgressCopy.warmingLine(tick: seen.count))
    }

    @Test("the ready line greets by name, and stands alone without one")
    func readyLine() {
        #expect(WakeProgressCopy.readyLine(name: "Kev").contains("Kev"))
        let nameless = WakeProgressCopy.readyLine(name: nil)
        #expect(!nameless.isEmpty)
        #expect(!nameless.contains(","))
    }
}

struct WakeAlertnessTests {
    @Test("the face wakes as the bar fills: dozing → stirring → alert → awake")
    func alertnessRamp() {
        #expect(WakeAlertness.at(fraction: 0.0, ready: false) == .dozing)
        #expect(WakeAlertness.at(fraction: 0.39, ready: false) == .dozing)
        #expect(WakeAlertness.at(fraction: 0.4, ready: false) == .stirring)
        #expect(WakeAlertness.at(fraction: 0.79, ready: false) == .stirring)
        #expect(WakeAlertness.at(fraction: 0.8, ready: false) == .alert)
        #expect(WakeAlertness.at(fraction: 0.99, ready: false) == .alert)
    }

    @Test("ready is awake regardless of what the bar last said")
    func readyIsAwake() {
        #expect(WakeAlertness.at(fraction: 0.1, ready: true) == .awake)
        #expect(WakeAlertness.at(fraction: 1.0, ready: true) == .awake)
    }
}
