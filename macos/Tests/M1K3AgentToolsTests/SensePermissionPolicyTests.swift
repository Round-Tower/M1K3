//
//  SensePermissionPolicyTests.swift
//  M1K3AgentToolsTests
//
//  The toggle-time permission rule (context-tools charter rule 4, amended
//  2026-09-23 after App Review asked why switching Calendar/Location on
//  raised no system alert): the OS prompt fires the moment the user switches
//  a sense ON — still after the in-app consent, never at launch, never when
//  switching OFF — and a refusal flips the toggle back.
//
//  Signed: Kev + claude-opus-5.5, 2026-09-23, Confidence 0.9 (red-first,
//  pure). Prior: none (new file).
//

@testable import M1K3AgentTools
import Testing

struct SensePermissionPolicyTests {
    @Test func switchingOnWithNoDecisionYetAsksTheOS() {
        #expect(SensePermissionPolicy.onToggle(enabled: true, status: .notDetermined) == .request)
    }

    @Test func switchingOnWhenAlreadyGrantedDoesNothing() {
        #expect(SensePermissionPolicy.onToggle(enabled: true, status: .granted) == .keep)
    }

    @Test func switchingOnWhenDeniedRevertsWithoutAPrompt() {
        // macOS never re-shows a denied prompt; the pane explains the Settings path.
        #expect(SensePermissionPolicy.onToggle(enabled: true, status: .denied) == .revert)
    }

    @Test func switchingOffNeverAsks() {
        for status in [SensePermissionStatus.notDetermined, .granted, .denied] {
            #expect(SensePermissionPolicy.onToggle(enabled: false, status: status) == .keep)
        }
    }

    @Test func theAnswerDecidesTheToggle() {
        #expect(SensePermissionPolicy.afterRequest(.granted) == .keep)
        #expect(SensePermissionPolicy.afterRequest(.denied) == .revert)
        // Dismissed without an answer (still undetermined): the toggle
        // cannot promise a sense macOS will not deliver — revert, ask again next time.
        #expect(SensePermissionPolicy.afterRequest(.notDetermined) == .revert)
    }
}
