//
//  TodoConsentPolicyTests.swift
//  M1K3TodosTests
//
//  Pins the consent shape: user-authored todos open at once, anything the
//  resident or a visitor writes lands pending, and ONLY the user moves a
//  todo between states. The resident may propose; it may never tidy.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-07, Confidence 0.9 (pure table,
//  every cell pinned). Prior: none (new file).
//

import Foundation
@testable import M1K3Todos
import Testing

struct TodoConsentPolicyTests {
    @Test("a user-authored todo opens immediately; resident and visitor land pending")
    func initialStates() {
        #expect(TodoConsentPolicy.initialState(for: .user) == .open)
        #expect(TodoConsentPolicy.initialState(for: .resident) == .pending)
        #expect(TodoConsentPolicy.initialState(for: .visitor(clientName: "Claude")) == .pending)
        #expect(TodoConsentPolicy.initialState(for: .visitor(clientName: nil)) == .pending)
    }

    @Test("only the user may accept, complete, dismiss or reopen")
    func onlyTheUser() {
        for actor in [TodoActor.resident, .visitor] {
            for state in TodoState.allCases {
                for transition in TodoTransition.allCases {
                    #expect(TodoConsentPolicy.resolve(transition, on: state, by: actor) == nil)
                }
            }
        }
        #expect(TodoConsentPolicy.resolve(.accept, on: .pending, by: .user) == .open)
        #expect(TodoConsentPolicy.resolve(.done, on: .open, by: .user) == .done)
        #expect(TodoConsentPolicy.resolve(.dismiss, on: .open, by: .user) == .dismissed)
        #expect(TodoConsentPolicy.resolve(.dismiss, on: .pending, by: .user) == .dismissed)
    }

    @Test("done and dismissed are terminal except for a user reopen")
    func terminalStates() {
        #expect(TodoConsentPolicy.resolve(.done, on: .done, by: .user) == nil)
        #expect(TodoConsentPolicy.resolve(.accept, on: .dismissed, by: .user) == nil)
        #expect(TodoConsentPolicy.resolve(.reopen, on: .done, by: .user) == .open)
        #expect(TodoConsentPolicy.resolve(.reopen, on: .dismissed, by: .user) == .open)
        #expect(TodoConsentPolicy.resolve(.reopen, on: .open, by: .user) == nil)
        #expect(TodoConsentPolicy.resolve(.accept, on: .open, by: .user) == nil)
        #expect(TodoConsentPolicy.resolve(.done, on: .pending, by: .user) == nil)
    }
}

struct ProposalCeilingTests {
    @Test("the resident may hold at most three pending proposals")
    func residentCeiling() {
        #expect(ProposalCeiling.residentMax == 3)
        #expect(ProposalCeiling.mayPropose(pendingResidentCount: 0))
        #expect(ProposalCeiling.mayPropose(pendingResidentCount: 2))
        #expect(!ProposalCeiling.mayPropose(pendingResidentCount: 3))
        #expect(!ProposalCeiling.mayPropose(pendingResidentCount: 9))
    }
}
