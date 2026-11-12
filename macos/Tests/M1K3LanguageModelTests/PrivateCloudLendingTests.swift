//
//  PrivateCloudLendingTests.swift
//  M1K3LanguageModelTests
//
//  Pins when Private Cloud Compute is lent to other apps on this Mac: only with
//  the lending switch on AND the chat rung's own gate open, and what a refused
//  call is told.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-12, Confidence 0.85, Prior: none (new file).
//

import Foundation
import M1K3LanguageModel
import Testing

struct PrivateCloudLendingTests {
    @Test("Nothing is offered with the lending switch off, whatever the rung says")
    func switchOffOffersNothing() {
        let controls: [PrivateCloudRung.Control] = [.hidden, .ready, .unavailable, .exhausted(resetsAt: nil)]
        for control in controls {
            #expect(PrivateCloudLending.offer(switchOn: false, control: control) == .notOffered)
        }
    }

    @Test("A hidden rung (no backend, org policy, the Privacy switch off) offers nothing even with the switch on")
    func hiddenRungOffersNothing() {
        #expect(PrivateCloudLending.offer(switchOn: true, control: .hidden) == .notOffered)
    }

    @Test("With both yeses the offer follows the rung")
    func offerFollowsTheRung() {
        let reset = Date(timeIntervalSince1970: 1000)
        #expect(PrivateCloudLending.offer(switchOn: true, control: .ready) == .ready)
        #expect(PrivateCloudLending.offer(switchOn: true, control: .unavailable) == .unavailable)
        let spent = PrivateCloudLending.offer(switchOn: true, control: .exhausted(resetsAt: reset))
        #expect(spent == .exhausted(resetsAt: reset))
    }

    @Test("The model is listed whenever it is offered, ready or not, so a client is told why instead of 'not found'")
    func listedWheneverOffered() {
        #expect(!PrivateCloudLending.Offer.notOffered.isListed)
        #expect(PrivateCloudLending.Offer.ready.isListed)
        #expect(PrivateCloudLending.Offer.unavailable.isListed)
        #expect(PrivateCloudLending.Offer.exhausted(resetsAt: nil).isListed)
    }

    @Test("Only a ready offer has no refusal; the others say why, and where the owner turns it on")
    func refusals() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(PrivateCloudLending.refusal(.ready, now: now) == nil)
        #expect(PrivateCloudLending.refusal(.notOffered, now: now)?.contains("Settings ▸ Server") == true)
        #expect(PrivateCloudLending.refusal(.unavailable, now: now)?.contains("isn't available right now") == true)
        let later = PrivateCloudLending.refusal(.exhausted(resetsAt: now.addingTimeInterval(3 * 3600)), now: now)
        #expect(later?.contains("limit") == true)
        #expect(later?.contains("in about 3 hours") == true)
    }

    @Test("The Settings row: gone where the rung cannot exist, a fact under org policy, locked until Privacy says yes")
    func settingsRow() {
        #expect(PrivateCloudLending.row(switchOn: true, setting: .hidden) == .hidden)
        #expect(PrivateCloudLending.row(switchOn: true, setting: .managedOff) == .managedOff)
        // The stored answer still shows: it would resume the moment Privacy is switched back on.
        let privacyOff = PrivateCloudRung.Setting.shown(isOn: false)
        #expect(PrivateCloudLending.row(switchOn: true, setting: privacyOff) == .needsPrivacySwitch(isOn: true))
        #expect(PrivateCloudLending.row(switchOn: false, setting: privacyOff) == .needsPrivacySwitch(isOn: false))
        #expect(PrivateCloudLending.row(switchOn: false, setting: .shown(isOn: true)) == .toggle(isOn: false))
        #expect(PrivateCloudLending.row(switchOn: true, setting: .shown(isOn: true)) == .toggle(isOn: true))
    }

    @Test("The cloud id is listed last, so a client that takes the first model stays on this Mac")
    func cloudIsListedLast() {
        #expect(PrivateCloudLending.modelIDs(local: ["lil-m1k3"], offer: .ready) == ["lil-m1k3", "cloud-m1k3"])
        #expect(PrivateCloudLending.modelIDs(local: ["lil-m1k3"], offer: .unavailable) == ["lil-m1k3", "cloud-m1k3"])
        #expect(PrivateCloudLending.modelIDs(local: ["lil-m1k3"], offer: .notOffered) == ["lil-m1k3"])
        #expect(PrivateCloudLending.modelIDs(local: [], offer: .ready) == ["cloud-m1k3"])
    }

    @Test("A local brain can never be listed under the cloud's id")
    func noLocalBrainTakesTheCloudID() {
        #expect(PrivateCloudLending.modelIDs(local: ["cloud-m1k3"], offer: .notOffered) == [])
    }

    @Test("Every failure on the cloud's side has a sentence for the caller", arguments: [
        PrivateCloudFailure.rateLimited, .quotaLimitReached(resetsAt: nil), .network, .unavailable, .other,
    ])
    func failureLines(failure: PrivateCloudFailure) {
        let line = PrivateCloudLending.failureLine(failure, now: Date(timeIntervalSince1970: 0))
        #expect(line.contains("Private Cloud Compute"))
    }

    @Test("The hourly budget lets thirty calls go, refuses the next with a wait, and frees up as the hour rolls")
    func budget() {
        var budget = PrivateCloudLending.Budget()
        let start = Date(timeIntervalSince1970: 0)
        for index in 0 ..< PrivateCloudLending.Budget.callsPerHour {
            #expect(budget.spend(now: start.addingTimeInterval(Double(index))) == nil)
        }
        // The first call was at 0 s, so at 100 s the next slot is 3,500 s away.
        #expect(budget.spend(now: start.addingTimeInterval(100)) == 3500)
        // A refused call takes nothing: at exactly one hour the first slot is free again.
        #expect(budget.spend(now: start.addingTimeInterval(3600)) == nil)
        #expect(budget.spend(now: start.addingTimeInterval(3600)) == 1)
    }

    @Test("The over-budget sentence names the limit and a wait in whole minutes")
    func overBudgetLine() {
        #expect(PrivateCloudLending.overBudgetLine(retryAfter: 3500).contains("about 59 minutes"))
        #expect(PrivateCloudLending.overBudgetLine(retryAfter: 20).contains("about 1 minute."))
        #expect(PrivateCloudLending.overBudgetLine(retryAfter: 20).contains("30 times"))
    }

    @Test("The model id says where the answer comes from")
    func modelID() {
        #expect(PrivateCloudLending.modelID == "cloud-m1k3")
    }
}
