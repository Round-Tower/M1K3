//
//  PrivateCloudRungTests.swift
//  M1K3LanguageModelTests
//
//  Pins the PCC rung's surfaces (ADR 0006): when the Settings switch and the
//  per-request control exist at all, when a request escalates, and what the user
//  is told when Private Cloud Compute can't answer. The "hidden" rows ARE the
//  1.0-parity guarantee: a build without a PCC backend, or with the org switch
//  set, shows nothing and never escalates.
//
//  Signed: Kev + claude-opus-5, 2026-09-14, Confidence 0.85, Prior: Unknown
//

import Foundation
@testable import M1K3LanguageModel
import Testing

struct PrivateCloudRungTests {
    private func state(
        backend: Bool = true, available: Bool = true, consent: Bool? = true,
        managedOff: Bool = false, quota: PrivateCloudQuota = .belowLimit
    ) -> PrivateCloudState {
        PrivateCloudState(
            backendPresent: backend, available: available, consent: consent,
            managedOff: managedOff, quota: quota
        )
    }

    // MARK: - The Settings switch

    @Test("no PCC backend in this build → the switch doesn't exist (1.0 parity)")
    func noBackendHidesTheSwitch() {
        for consent in [nil, false, true] as [Bool?] {
            #expect(PrivateCloudRung.setting(state(backend: false, consent: consent)) == .hidden)
        }
    }

    @Test("the org switch wins over the user's consent")
    func managedOffBeatsConsent() {
        #expect(PrivateCloudRung.setting(state(consent: true, managedOff: true)) == .managedOff)
    }

    @Test("no backend beats the org switch: nothing to show, not even 'turned off by your organisation'")
    func noBackendBeatsManagedOff() {
        #expect(PrivateCloudRung.setting(state(backend: false, managedOff: true)) == .hidden)
    }

    @Test("never answered is OFF — consent is given, not assumed")
    func absentConsentIsOff() {
        #expect(PrivateCloudRung.setting(state(consent: nil)) == .shown(isOn: false))
        #expect(PrivateCloudRung.setting(state(consent: false)) == .shown(isOn: false))
        #expect(PrivateCloudRung.setting(state(consent: true)) == .shown(isOn: true))
    }

    @Test("a temporarily unavailable PCC keeps the switch — it's a preference, not a status")
    func unavailableKeepsTheSwitch() {
        #expect(PrivateCloudRung.setting(state(available: false, consent: true)) == .shown(isOn: true))
    }

    // MARK: - The per-request control

    @Test("the control needs the switch on")
    func controlNeedsConsent() {
        #expect(PrivateCloudRung.control(state(consent: nil)) == .hidden)
        #expect(PrivateCloudRung.control(state(consent: false)) == .hidden)
        #expect(PrivateCloudRung.control(state(consent: true, managedOff: true)) == .hidden)
        #expect(PrivateCloudRung.control(state(backend: false, consent: true)) == .hidden)
        #expect(PrivateCloudRung.control(state(consent: true)) == .ready)
    }

    @Test("quota at the limit shows the control as exhausted, with the reset date")
    func quotaExhausted() {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(PrivateCloudRung.control(state(quota: .limitReached(resetsAt: reset))) == .exhausted(resetsAt: reset))
        #expect(PrivateCloudRung.control(state(quota: .limitReached(resetsAt: nil))) == .exhausted(resetsAt: nil))
        // An unread quota is not a reason to refuse — the send finds out.
        #expect(PrivateCloudRung.control(state(quota: .unknown)) == .ready)
    }

    @Test("unavailable right now shows the control as unavailable, not hidden")
    func unavailableControl() {
        #expect(PrivateCloudRung.control(state(available: false)) == .unavailable)
    }

    // MARK: - Escalation (the only door to the ladder's PCC rung)

    @Test("a request escalates only when the user armed it AND the control is ready")
    func escalationNeedsBoth() {
        #expect(PrivateCloudRung.escalation(armed: true, state()) == .privateCloud)
        #expect(PrivateCloudRung.escalation(armed: false, state()) == .none)
    }

    @Test("every input combination that isn't ready → no escalation, even when armed")
    func notReadyNeverEscalates() {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        for backend in [false, true] {
            for available in [false, true] {
                for consent in [nil, false, true] as [Bool?] {
                    for managedOff in [false, true] {
                        for quota in [PrivateCloudQuota.belowLimit, .unknown, .limitReached(resetsAt: reset)] {
                            let s = state(
                                backend: backend, available: available, consent: consent,
                                managedOff: managedOff, quota: quota
                            )
                            let escalated = PrivateCloudRung.escalation(armed: true, s) == .privateCloud
                            #expect(escalated == (PrivateCloudRung.control(s) == .ready), "\(s)")
                        }
                    }
                }
            }
        }
    }

    /// ADR 0006: images never ride a PCC turn, and an armed send is only honoured
    /// while the control is ready. This used to live as a three-clause `if` in
    /// ContentView, where a dropped clause would ship untested.
    @Test("an armed send opens the consent sheet only when ready and no image is staged")
    func presentsConsentOnlyWhenHonourable() {
        #expect(PrivateCloudRung.presentsConsent(armed: true, control: .ready, hasAttachments: false))
        #expect(!PrivateCloudRung.presentsConsent(armed: false, control: .ready, hasAttachments: false))
        #expect(!PrivateCloudRung.presentsConsent(armed: true, control: .ready, hasAttachments: true))
        for control: PrivateCloudRung.Control in [.hidden, .unavailable, .exhausted(resetsAt: nil)] {
            #expect(!PrivateCloudRung.presentsConsent(armed: true, control: control, hasAttachments: false))
        }
    }

    @Test("the control's tooltip says what the click does, and when an exhausted limit resets")
    func controlHelpNamesTheReset() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(PrivateCloudRung.controlHelp(.ready, armed: false, now: now)
            == "Use Apple's Private Cloud Compute for this conversation")
        #expect(PrivateCloudRung.controlHelp(.ready, armed: true, now: now)
            == "On: this conversation goes to Private Cloud Compute until you turn it off")
        #expect(PrivateCloudRung.controlHelp(.unavailable, armed: false, now: now)
            == "Private Cloud Compute isn't available right now")
        let inThreeHours = now.addingTimeInterval(3 * 3600)
        #expect(PrivateCloudRung.controlHelp(.exhausted(resetsAt: inThreeHours), armed: false, now: now)
            == "You've reached your Private Cloud Compute limit. It resets in about 3 hours.")
        #expect(PrivateCloudRung.controlHelp(.exhausted(resetsAt: nil), armed: false, now: now)
            == "You've reached your Private Cloud Compute limit for now")
        #expect(PrivateCloudRung.controlHelp(.hidden, armed: false, now: now).isEmpty)
    }

    /// Review on 7b36869e: an exhausted or unavailable control had no way back to
    /// ready without a relaunch (the status was read at launch and after a send,
    /// and a disabled control can't send). It now re-reads on this schedule.
    @Test("a control that can't be used re-reads PCC's status: at the reset, capped at 5 minutes")
    func statusRecheckDelay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(PrivateCloudRung.statusRecheckDelay(for: .ready, now: now) == nil)
        #expect(PrivateCloudRung.statusRecheckDelay(for: .hidden, now: now) == nil)
        #expect(PrivateCloudRung.statusRecheckDelay(for: .unavailable, now: now) == 60)
        let inThreeHours = now.addingTimeInterval(3 * 3600)
        #expect(PrivateCloudRung.statusRecheckDelay(for: .exhausted(resetsAt: inThreeHours), now: now) == 300)
        #expect(PrivateCloudRung.statusRecheckDelay(for: .exhausted(resetsAt: now.addingTimeInterval(90)), now: now)
            == 90)
        // Past the reset but still exhausted: re-read soon, never in a tight loop.
        #expect(PrivateCloudRung.statusRecheckDelay(for: .exhausted(resetsAt: now.addingTimeInterval(-10)), now: now)
            == 30)
        #expect(PrivateCloudRung.statusRecheckDelay(for: .exhausted(resetsAt: nil), now: now) == 300)
    }

    @Test("the ladder's egress gate: consent AND not managed off AND a backend")
    func networkAllowed() {
        #expect(PrivateCloudRung.networkAllowed(state()))
        #expect(!PrivateCloudRung.networkAllowed(state(consent: nil)))
        #expect(!PrivateCloudRung.networkAllowed(state(managedOff: true)))
        #expect(!PrivateCloudRung.networkAllowed(state(backend: false)))
    }

    @Test("with the gate closed, the ladder never picks PCC — even if escalation leaked through")
    func ladderHonoursTheGate() {
        let catalogue = BrainCatalogue.standard()
        let closed = state(consent: false)
        let context = LadderContext(
            appleIntelligenceAvailable: true,
            networkAllowed: PrivateCloudRung.networkAllowed(closed),
            userEscalation: .privateCloud
        )
        #expect(catalogue.route(context)?.reach == .onDevice)
    }

    // MARK: - Failure → the local brain answers, and says why

    @Test("every failure names Private Cloud Compute and the local brain — never an empty line")
    func fallbackNoticeIsNeverEmpty() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let failures: [PrivateCloudFailure] = [
            .rateLimited, .quotaLimitReached(resetsAt: nil),
            .quotaLimitReached(resetsAt: now.addingTimeInterval(3 * 3600)),
            .network, .unavailable, .other,
        ]
        for failure in failures {
            let line = PrivateCloudFallback.notice(for: failure, localBrain: "Mini", now: now)
            #expect(line.contains("Private Cloud Compute"), "\(failure)")
            #expect(line.contains("Mini"), "\(failure)")
            #expect(line.hasSuffix("."), "\(failure)")
        }
    }

    @Test("a quota notice says when it resets, in words")
    func quotaResetPhrase() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let soon = PrivateCloudFallback.notice(
            for: .quotaLimitReached(resetsAt: now.addingTimeInterval(50 * 60)), localBrain: "Lil", now: now
        )
        #expect(soon.contains("in about an hour"))
        let later = PrivateCloudFallback.notice(
            for: .quotaLimitReached(resetsAt: now.addingTimeInterval(5 * 3600 + 10)), localBrain: "Lil", now: now
        )
        #expect(later.contains("in about 6 hours"))
        let tomorrow = PrivateCloudFallback.notice(
            for: .quotaLimitReached(resetsAt: now.addingTimeInterval(30 * 3600)), localBrain: "Lil", now: now
        )
        #expect(tomorrow.contains("tomorrow"))
        let unknown = PrivateCloudFallback.notice(for: .quotaLimitReached(resetsAt: nil), localBrain: "Lil", now: now)
        #expect(!unknown.contains("resets"))
    }

    @Test("a mid-answer failure says the answer is partial and offers the local brain — it claims no local answer")
    func midAnswerNotice() {
        let failures: [PrivateCloudFailure] = [
            .rateLimited, .quotaLimitReached(resetsAt: nil), .network, .unavailable, .other,
        ]
        for failure in failures {
            let line = PrivateCloudFallback.midAnswerNotice(for: failure, localBrain: "Mini")
            #expect(line.contains("Private Cloud Compute"), "\(failure)")
            #expect(line.contains("partway"), "\(failure)")
            #expect(line.contains("Mini"), "\(failure)")
            #expect(!line.contains("answered here instead"), "\(failure)")
        }
    }

    /// Seen by launch: a 45-second reset read "in about an hour" (everything
    /// under an hour rounded up to one). Coarse is fine; untrue is not.
    @Test("a reset minutes away never reads as an hour away")
    func subHourResetPhrases() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(PrivateCloudFallback.resetPhrase(until: now.addingTimeInterval(45), now: now) == "shortly")
        #expect(PrivateCloudFallback.resetPhrase(until: now.addingTimeInterval(20 * 60), now: now) == "within the hour")
        #expect(PrivateCloudFallback.resetPhrase(until: now.addingTimeInterval(50 * 60), now: now) == "in about an hour")
    }

    @Test("a reset time already past reads as 'shortly', not a negative duration")
    func pastResetIsShortly() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let line = PrivateCloudFallback.notice(
            for: .quotaLimitReached(resetsAt: now.addingTimeInterval(-60)), localBrain: "Mini", now: now
        )
        #expect(line.contains("shortly"))
    }

    // MARK: - The label every PCC answer carries

    @Test("the label names Apple's Private Cloud Compute")
    func labelText() {
        #expect(PrivateCloudLabel.text == "Private Cloud Compute")
        #expect(PrivateCloudLabel.accessibilityLabel.contains("Apple's Private Cloud Compute"))
    }
}
