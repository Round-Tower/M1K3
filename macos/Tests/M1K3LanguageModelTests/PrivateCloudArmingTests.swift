import Foundation
@testable import M1K3LanguageModel
import Testing

/// PCC stays on once the user turns it on (Kev, 2026-09-26): one consent per
/// conversation, then every send in it goes to Private Cloud Compute until the
/// user turns it off or the conversation changes.
struct PrivateCloudArmingTests {
    @Test("off by default: every send stays on this Mac")
    func offByDefault() {
        let arming = PrivateCloudArming()
        #expect(!arming.isOn)
        #expect(arming.action(control: .ready, hasAttachments: false) == .local)
    }

    @Test("turned on, the first send asks for consent")
    func firstSendAsks() {
        var arming = PrivateCloudArming()
        arming.toggle()
        #expect(arming.action(control: .ready, hasAttachments: false) == .askConsent)
    }

    @Test("after consent it stays on, and later sends skip the sheet with the same choice")
    func staysOnAfterConsent() {
        var arming = PrivateCloudArming()
        arming.toggle()
        arming.consented(includeConversation: true)
        #expect(arming.isOn)
        #expect(arming.action(control: .ready, hasAttachments: false) == .sendDirect(includeConversation: true))
        #expect(arming.action(control: .ready, hasAttachments: false) == .sendDirect(includeConversation: true))
    }

    @Test("\"Keep it on this Mac\" turns it off and forgets the consent")
    func declineTurnsOff() {
        var arming = PrivateCloudArming()
        arming.toggle()
        arming.declined()
        #expect(!arming.isOn)
        arming.toggle()
        #expect(arming.action(control: .ready, hasAttachments: false) == .askConsent)
    }

    @Test("turning it off by hand and back on asks again")
    func manualOffForgetsConsent() {
        var arming = PrivateCloudArming()
        arming.toggle()
        arming.consented(includeConversation: false)
        arming.toggle()
        #expect(!arming.isOn)
        arming.toggle()
        #expect(arming.action(control: .ready, hasAttachments: false) == .askConsent)
    }

    @Test("a new or switched conversation turns it off: consent never crosses conversations")
    func conversationChangeTurnsOff() {
        var arming = PrivateCloudArming()
        arming.toggle()
        arming.consented(includeConversation: true)
        arming.conversationChanged()
        #expect(!arming.isOn)
        #expect(arming.action(control: .ready, hasAttachments: false) == .local)
    }

    @Test("a control that can't be honoured turns it off")
    func unreadyControlTurnsOff() {
        for control: PrivateCloudRung.Control in [.hidden, .unavailable, .exhausted(resetsAt: nil)] {
            var arming = PrivateCloudArming()
            arming.toggle()
            arming.consented(includeConversation: true)
            arming.controlChanged(control)
            #expect(!arming.isOn)
        }
        var stillReady = PrivateCloudArming()
        stillReady.toggle()
        stillReady.controlChanged(.ready)
        #expect(stillReady.isOn)
    }

    @Test("a staged attachment turns it off: images and files never ride a PCC turn")
    func attachmentTurnsOff() {
        var arming = PrivateCloudArming()
        arming.toggle()
        arming.consented(includeConversation: true)
        arming.attachmentsStaged()
        #expect(!arming.isOn)
    }

    @Test("never escalates while the control isn't ready or something is staged")
    func neverEscalatesUnhonourably() {
        var arming = PrivateCloudArming()
        arming.toggle()
        arming.consented(includeConversation: true)
        #expect(arming.action(control: .unavailable, hasAttachments: false) == .local)
        #expect(arming.action(control: .ready, hasAttachments: true) == .local)
    }
}
