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
}
