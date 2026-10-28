//
//  UserStyleRefreshGateTests.swift
//  M1K3InferenceTests
//
//  Pins the stated-style refresh order (#730 audit, 2026-10-28). Every test drives a
//  local gate: the persona's own style is process-global and no test may set it.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-28, Confidence 0.9, Prior: none (new file)
//

@testable import M1K3Inference
import Testing

private final class Applied {
    var history: [[String]] = []
}

struct UserStyleRefreshGateTests {
    @Test("a stale read that finishes after a newer refresh is dropped, so a forgotten ask stays gone")
    func staleReadLandingLastIsDropped() {
        let gate = UserStyleRefreshGate()
        let applied = Applied()
        // The first refresh reads the style before a forget; while it is still reading, the
        // forget's own refresh starts, reads nothing, and applies.
        let first = gate.refresh(
            read: {
                gate.refresh(read: { [] }, apply: { applied.history.append($0) })
                return ["The user prefers short answers."]
            },
            apply: { applied.history.append($0) }
        )
        #expect(!first)
        #expect(applied.history == [[]])
    }

    @Test("refreshes that don't overlap all apply, newest last")
    func inOrderRefreshesApply() {
        let gate = UserStyleRefreshGate()
        let applied = Applied()
        #expect(gate.refresh(read: { ["a"] }, apply: { applied.history.append($0) }))
        #expect(gate.refresh(read: { ["b", "a"] }, apply: { applied.history.append($0) }))
        #expect(applied.history == [["a"], ["b", "a"]])
    }

    @Test("a failed read applies nothing, so the style in place stays")
    func failedReadKeepsStyle() {
        struct ReadFailed: Error {}
        let gate = UserStyleRefreshGate()
        let applied = Applied()
        gate.refresh(read: { ["a"] }, apply: { applied.history.append($0) })
        #expect(!gate.refresh(read: { throw ReadFailed() }, apply: { applied.history.append($0) }))
        #expect(applied.history == [["a"]])
    }

    @Test("a refresh after a dropped one still applies")
    func refreshAfterDropApplies() {
        let gate = UserStyleRefreshGate()
        let applied = Applied()
        gate.refresh(
            read: {
                gate.refresh(read: { ["new"] }, apply: { applied.history.append($0) })
                return ["stale"]
            },
            apply: { applied.history.append($0) }
        )
        #expect(gate.refresh(read: { ["newer"] }, apply: { applied.history.append($0) }))
        #expect(applied.history == [["new"], ["newer"]])
    }
}
