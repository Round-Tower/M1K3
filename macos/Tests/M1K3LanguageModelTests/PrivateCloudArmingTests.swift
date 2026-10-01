import Foundation
@testable import M1K3LanguageModel
import Testing

/// PCC is a brain-picker choice that holds over time, and its consent is asked
/// ONCE (Kev, 2026-10-01: "PCC moved to the brain picker - holds over time";
/// "I think it should be once"). The pick and the sheet's answer persist until
/// the user un-picks PCC. One exception keeps "you see what leaves" true: with
/// "also send this conversation" stored, any message that never left this Mac
/// re-asks until a sheet has shown it — by message id, never by conversation.
struct PrivateCloudArmingTests {
    private let withHistory = PrivateCloudArming.Action.sendDirect(includeConversation: true)
    private let messageOnly = PrivateCloudArming.Action.sendDirect(includeConversation: false)
    /// On-device message ids in the history PCC would be shown.
    private let turnA: Set<UUID> = [UUID(), UUID()]
    private let turnB: Set<UUID> = [UUID()]

    private func act(
        _ arming: PrivateCloudArming,
        control: PrivateCloudRung.Control = .ready,
        attachments: Bool = false,
        onDevice: Set<UUID> = []
    ) -> PrivateCloudArming.Action {
        arming.action(control: control, hasAttachments: attachments, onDeviceMessages: onDevice)
    }

    @Test("off by default: every send stays on this Mac")
    func offByDefault() {
        let arming = PrivateCloudArming()
        #expect(!arming.isOn)
        #expect(arming.consent == nil)
        #expect(act(arming) == .local)
    }

    @Test("picked, the first send ever asks for consent")
    func firstSendAsks() {
        var arming = PrivateCloudArming()
        arming.select(true)
        #expect(act(arming) == .askConsent)
    }

    @Test("once: after the sheet, later sends skip it with the same choice")
    func consentIsAskedOnce() {
        var arming = PrivateCloudArming()
        arming.select(true)
        arming.consented(includeConversation: false, seen: [])
        #expect(act(arming) == messageOnly)
        // Message only: on-device history never rides, so it never asks.
        #expect(act(arming, onDevice: turnA) == messageOnly)
    }

    @Test("a relaunch restores the pick AND the answer: no sheet for PCC-only history")
    func restoredFromDefaults() {
        let arming = PrivateCloudArming(isOn: true, consent: true)
        #expect(act(arming) == withHistory)
    }

    @Test("a relaunch never restores what was seen: on-device history asks again")
    func seenIsNotRestored() {
        let arming = PrivateCloudArming(isOn: true, consent: true)
        #expect(act(arming, onDevice: turnA) == .askConsent)
    }

    @Test("a stored consent without the pick is ignored")
    func consentWithoutPickIsInert() {
        let arming = PrivateCloudArming(isOn: false, consent: true)
        #expect(arming.consent == nil)
        #expect(act(arming) == .local)
    }

    @Test("on-device history shows the sheet once; what it showed never asks again")
    func onDeviceHistoryAsksUntilSeen() {
        var arming = PrivateCloudArming()
        arming.select(true)
        arming.consented(includeConversation: true, seen: [])
        #expect(act(arming) == withHistory)
        #expect(act(arming, onDevice: turnA) == .askConsent)
        arming.consented(includeConversation: true, seen: turnA)
        #expect(act(arming, onDevice: turnA) == withHistory)
    }

    /// Round-two review (a): a conversation cleared once used to stay cleared
    /// while new local turns (an attachment, an outage, voice) landed in it.
    @Test("a new on-device answer after the sheet asks again — clearing is by message, not conversation")
    func newLocalTurnAsksAgain() {
        var arming = PrivateCloudArming()
        arming.select(true)
        arming.consented(includeConversation: true, seen: turnA)
        #expect(act(arming, onDevice: turnA.union(turnB)) == .askConsent)
    }

    @Test("a sheet answered after a switch clears only the messages it showed")
    func lateSheetClearsWhatItShowed() {
        var arming = PrivateCloudArming()
        arming.select(true)
        arming.consented(includeConversation: true, seen: turnA) // opened in A, B is active now
        #expect(act(arming, onDevice: turnB) == .askConsent)
    }

    @Test("\"Keep it on this Mac\" un-picks and forgets the consent")
    func declineTurnsOff() {
        var arming = PrivateCloudArming()
        arming.select(true)
        arming.consented(includeConversation: true, seen: turnA)
        arming.declined()
        #expect(!arming.isOn)
        #expect(arming.consent == nil)
        arming.select(true)
        #expect(act(arming) == .askConsent)
    }

    @Test("picking a brain on this Mac forgets the consent and what was seen")
    func pickingLocalForgets() {
        var arming = PrivateCloudArming()
        arming.select(true)
        arming.consented(includeConversation: true, seen: turnA)
        arming.select(false)
        #expect(!arming.isOn)
        #expect(arming.consent == nil)
        arming.select(true)
        arming.consented(includeConversation: true, seen: [])
        #expect(act(arming, onDevice: turnA) == .askConsent)
    }

    @Test("re-picking PCC while on keeps the consent")
    func reselectKeepsConsent() {
        var arming = PrivateCloudArming()
        arming.select(true)
        arming.consented(includeConversation: true, seen: [])
        arming.select(true)
        #expect(act(arming) == withHistory)
    }

    @Test("a passing outage or an exhausted limit keeps the pick; sends stay local until it's back")
    func transientControlKeepsPick() {
        for control: PrivateCloudRung.Control in [.unavailable, .exhausted(resetsAt: nil)] {
            var arming = PrivateCloudArming()
            arming.select(true)
            arming.consented(includeConversation: true, seen: [])
            arming.controlChanged(control)
            #expect(arming.isOn)
            #expect(act(arming, control: control) == .local)
            #expect(!arming.servesNextSend(control: control, hasAttachments: false))
            arming.controlChanged(.ready)
            #expect(act(arming) == withHistory)
        }
    }

    @Test("a rung that no longer exists (Settings switch off, org policy) un-picks and forgets")
    func hiddenControlTurnsOff() {
        var arming = PrivateCloudArming()
        arming.select(true)
        arming.consented(includeConversation: true, seen: [])
        arming.controlChanged(.hidden)
        #expect(!arming.isOn)
        #expect(arming.consent == nil)
    }

    @Test("a staged attachment keeps the pick, but that send stays on this Mac")
    func attachmentSendsLocal() {
        var arming = PrivateCloudArming()
        arming.select(true)
        arming.consented(includeConversation: true, seen: [])
        #expect(act(arming, attachments: true) == .local)
        #expect(!arming.servesNextSend(control: .ready, hasAttachments: true))
        #expect(arming.isOn)
        #expect(act(arming) == withHistory)
    }

    @Test("a consent can't be recorded while PCC isn't picked")
    func consentNeedsThePick() {
        var arming = PrivateCloudArming()
        arming.consented(includeConversation: true, seen: [])
        #expect(arming.consent == nil)
    }

    @Test("servesNextSend is true only when the next send would leave for PCC")
    func servesNextSend() {
        var arming = PrivateCloudArming()
        #expect(!arming.servesNextSend(control: .ready, hasAttachments: false))
        arming.select(true)
        #expect(arming.servesNextSend(control: .ready, hasAttachments: false))
        #expect(!arming.servesNextSend(control: .hidden, hasAttachments: false))
    }
}
