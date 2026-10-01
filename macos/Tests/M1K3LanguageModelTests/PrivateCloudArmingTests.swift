import Foundation
@testable import M1K3LanguageModel
import Testing

/// PCC is a brain-picker choice that holds over time, and its consent is asked
/// ONCE (Kev, 2026-10-01: "PCC moved to the brain picker - holds over time";
/// "I think it should be once"). The pick and the sheet's answer persist until
/// the user un-picks PCC. One exception keeps "you see what leaves" true: with
/// "also send this conversation" stored, a conversation holding on-device
/// answers — history that never left this Mac — shows the sheet once itself.
struct PrivateCloudArmingTests {
    private let chatA = UUID()
    private let chatB = UUID()
    private let withHistory = PrivateCloudArming.Action.sendDirect(includeConversation: true)
    private let messageOnly = PrivateCloudArming.Action.sendDirect(includeConversation: false)

    private func act(
        _ arming: PrivateCloudArming,
        in chat: UUID? = nil,
        control: PrivateCloudRung.Control = .ready,
        attachments: Bool = false,
        local: Bool = false
    ) -> PrivateCloudArming.Action {
        arming.action(in: chat ?? chatA, control: control, hasAttachments: attachments, holdsOnDeviceAnswers: local)
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

    @Test("once: after the sheet, sends in any conversation skip it with the same choice")
    func consentIsAskedOnce() {
        var arming = PrivateCloudArming()
        arming.select(true)
        arming.consented(includeConversation: false, in: chatA)
        #expect(act(arming, in: chatA) == messageOnly)
        #expect(act(arming, in: chatB) == messageOnly)
        #expect(act(arming, in: chatB, local: true) == messageOnly)
    }

    @Test("a relaunch restores the pick AND the answer: no sheet")
    func restoredFromDefaults() {
        let arming = PrivateCloudArming(isOn: true, consent: true)
        #expect(act(arming, in: chatB) == withHistory)
    }

    @Test("a stored consent without the pick is ignored")
    func consentWithoutPickIsInert() {
        let arming = PrivateCloudArming(isOn: false, consent: true)
        #expect(act(arming) == .local)
    }

    @Test("history that never left this Mac shows the sheet once, in that conversation")
    func onDeviceHistoryAsksOncePerConversation() {
        var arming = PrivateCloudArming()
        arming.select(true)
        arming.consented(includeConversation: true, in: chatA)
        #expect(act(arming, in: chatA, local: true) == withHistory)
        // B holds on-device answers nobody saw leave: ask, once.
        #expect(act(arming, in: chatB, local: true) == .askConsent)
        arming.consented(includeConversation: true, in: chatB)
        #expect(act(arming, in: chatB, local: true) == withHistory)
        // A conversation of only PCC turns never asks again.
        #expect(act(arming, in: UUID(), local: false) == withHistory)
    }

    @Test("a sheet answered after a switch clears only the conversation it was shown in")
    func lateSheetClearsItsOwnConversation() {
        var arming = PrivateCloudArming()
        arming.select(true)
        arming.consented(includeConversation: true, in: chatA) // opened in A, B is active now
        #expect(act(arming, in: chatB, local: true) == .askConsent)
    }

    @Test("\"Keep it on this Mac\" un-picks and forgets the consent")
    func declineTurnsOff() {
        var arming = PrivateCloudArming()
        arming.select(true)
        arming.consented(includeConversation: true, in: chatA)
        arming.declined()
        #expect(!arming.isOn)
        #expect(arming.consent == nil)
        arming.select(true)
        #expect(act(arming) == .askConsent)
    }

    @Test("picking a brain on this Mac forgets the consent; picking PCC again asks again")
    func pickingLocalForgetsConsent() {
        var arming = PrivateCloudArming()
        arming.select(true)
        arming.consented(includeConversation: false, in: chatA)
        arming.select(false)
        #expect(!arming.isOn)
        #expect(arming.consent == nil)
        arming.select(true)
        #expect(act(arming) == .askConsent)
    }

    @Test("re-picking PCC while on keeps the consent")
    func reselectKeepsConsent() {
        var arming = PrivateCloudArming()
        arming.select(true)
        arming.consented(includeConversation: true, in: chatA)
        arming.select(true)
        #expect(act(arming) == withHistory)
    }

    @Test("a passing outage or an exhausted limit keeps the pick; sends stay local until it's back")
    func transientControlKeepsPick() {
        for control: PrivateCloudRung.Control in [.unavailable, .exhausted(resetsAt: nil)] {
            var arming = PrivateCloudArming()
            arming.select(true)
            arming.consented(includeConversation: true, in: chatA)
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
        arming.consented(includeConversation: true, in: chatA)
        arming.controlChanged(.hidden)
        #expect(!arming.isOn)
        #expect(arming.consent == nil)
    }

    @Test("a staged attachment keeps the pick, but that send stays on this Mac")
    func attachmentSendsLocal() {
        var arming = PrivateCloudArming()
        arming.select(true)
        arming.consented(includeConversation: true, in: chatA)
        #expect(act(arming, attachments: true) == .local)
        #expect(!arming.servesNextSend(control: .ready, hasAttachments: true))
        #expect(arming.isOn)
        #expect(act(arming) == withHistory)
    }

    @Test("a consent can't be recorded while PCC isn't picked")
    func consentNeedsThePick() {
        var arming = PrivateCloudArming()
        arming.consented(includeConversation: true, in: chatA)
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
