//
//  HeartbeatPromptTests.swift
//  M1K3HeartbeatTests
//
//  Pins the narrative-render prompt: the model gets the digest verbatim, the
//  day's earlier pulses for the arc, an explicit add-nothing rule, and the
//  house noun ("machine", never "Mac" — the ratified platform-honesty split).
//
//  Signed: Kev + claude-fable-5, 2026-08-06, Confidence 0.85 (string
//  contract pinned; whether the prompt WORKS on Big/Lil is a named
//  verify-owed on-device run, not claimable from here). Prior: none (new file).
//

@testable import M1K3Heartbeat
import Testing

struct HeartbeatPromptTests {
    @Test("the prompt carries the digest verbatim and the add-nothing rule")
    func digestAndRule() {
        let prompt = HeartbeatPrompt.render(digest: "Battery at 84%.", earlierToday: [])
        #expect(prompt.contains("Battery at 84%."))
        #expect(prompt.lowercased().contains("do not add"))
    }

    @Test("earlier pulses thread the day's arc, oldest first")
    func earlierPulses() {
        let prompt = HeartbeatPrompt.render(
            digest: "Quiet stretch.",
            earlierToday: ["Slow start.", "Warming up."]
        )
        let slowStart = try? #require(prompt.range(of: "Slow start."))
        let warmingUp = try? #require(prompt.range(of: "Warming up."))
        if let slowStart, let warmingUp {
            #expect(slowStart.lowerBound < warmingUp.lowerBound)
        }
    }

    @Test("no earlier pulses, no arc section")
    func noArcSection() {
        let prompt = HeartbeatPrompt.render(digest: "Quiet stretch.", earlierToday: [])
        #expect(!prompt.contains("Earlier today"))
    }

    @Test("the prompt says machine, never Mac")
    func machineNotMac() {
        let prompt = HeartbeatPrompt.render(digest: "Quiet stretch.", earlierToday: ["Slow start."])
        #expect(!prompt.contains("Mac"))
        #expect(prompt.lowercased().contains("machine"))
    }

    // MARK: - The 2026-08-30 register rules (addendum fixes 2, 4, 7)

    @Test("the prompt leads with the news and demotes ambient state")
    func leadWithNews() {
        let prompt = HeartbeatPrompt.render(digest: "News:\nWe talked.", earlierToday: [])
        #expect(prompt.lowercased().contains("lead with the news"))
    }

    @Test("the brain is what M1K3 thinks with, never a companion")
    func brainIsATool() {
        let prompt = HeartbeatPrompt.render(digest: "Running on Big.", earlierToday: [])
        #expect(prompt.lowercased().contains("never a companion"))
    }

    @Test("report what happened; never claim work (the 'I've stayed busy' pulse)")
    func neverClaimWork() {
        let prompt = HeartbeatPrompt.render(digest: "Quiet stretch.", earlierToday: [])
        #expect(prompt.lowercased().contains("never claim"))
    }

    @Test("recent openers are quoted with a don't-open-like-these rule (three days, one sentence)")
    func recentOpenersListed() {
        let prompt = HeartbeatPrompt.render(
            digest: "Quiet stretch.",
            earlierToday: [],
            recentPulses: ["I'm keeping things steady on this end; the machine is cool and we've been up four days."]
        )
        #expect(prompt.contains("I'm keeping things steady on this end"))
        #expect(prompt.lowercased().contains("do not open"))
        // The opener excerpt, not the whole pulse — the tail stays out.
        #expect(!prompt.contains("up four days"))
    }

    @Test("no recent pulses, no openers section")
    func noOpenersSection() {
        let prompt = HeartbeatPrompt.render(digest: "Quiet stretch.", earlierToday: [])
        #expect(!prompt.lowercased().contains("do not open"))
    }
}
