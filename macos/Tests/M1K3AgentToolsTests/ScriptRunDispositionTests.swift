//
//  ScriptRunDispositionTests.swift
//  M1K3AgentToolsTests
//
//  The one classifier both the agent tool (execute_script, fenced for the
//  model) and the app's Install & Run (plain display) branch on, so their
//  outcome→message logic can't silently diverge. Pure + Equatable → tested
//  without a runner. The subtle rules are pinned here: a timed-out run is never
//  "succeeded", and failureReason nil-coalesces to a stable string.
//
//  Signed: Kev + claude-opus-4-8, 2026-08-23, Confidence 0.9, Prior: Unknown

import Foundation
@testable import M1K3AgentTools
import Testing

struct ScriptRunDispositionTests {
    @Test("a clean exit is .succeeded")
    func succeeds() {
        let outcome = ScriptRunOutcome(
            succeeded: true, failureReason: nil, output: "ok", duration: 0.1, timedOut: false
        )
        #expect(ScriptRunDisposition(outcome) == .succeeded)
    }

    @Test("a non-zero exit carries its reason")
    func failsWithReason() {
        let outcome = ScriptRunOutcome(
            succeeded: false, failureReason: "exit 3", output: "boom", duration: 0.2, timedOut: false
        )
        #expect(ScriptRunDisposition(outcome) == .failed(reason: "exit 3"))
    }

    @Test("a failure with no reason nil-coalesces to a stable string")
    func failsWithoutReason() {
        let outcome = ScriptRunOutcome(
            succeeded: false, failureReason: nil, output: "", duration: 0.2, timedOut: false
        )
        #expect(ScriptRunDisposition(outcome) == .failed(reason: "unknown failure"))
    }

    @Test("a timeout is .timedOut even if the exit looked clean — never a success")
    func timeoutWinsOverSuccess() {
        // The wait was abandoned; the script may still be running. This must
        // never read as success, whatever the succeeded flag happens to say.
        let outcome = ScriptRunOutcome(
            succeeded: true, failureReason: nil, output: "partial", duration: 30, timedOut: true
        )
        #expect(ScriptRunDisposition(outcome) == .timedOut)
    }
}
