import Foundation
@testable import M1K3LanguageModel
import Testing

/// PCC is a brain-picker choice that holds over time (Kev, 2026-10-01): once
/// picked it stays picked, across conversations and relaunches, until the user
/// picks a brain on this Mac or says "Keep it on this Mac". Consent is still
/// asked once per conversation: the sheet's include-the-conversation answer
/// belongs to the conversation it was given in.
struct PrivateCloudArmingTests {
    private let chatA = UUID()
    private let chatB = UUID()
    /// The sheet's yes with the conversation included, reused.
    private let direct = PrivateCloudArming.Action.sendDirect(includeConversation: true)

    @Test("off by default: every send stays on this Mac")
    func offByDefault() {
        let arming = PrivateCloudArming()
        #expect(!arming.isOn)
        #expect(arming.action(in: chatA, control: .ready, hasAttachments: false) == .local)
    }

    @Test("restored on: a relaunch keeps the user's pick, and the first send asks")
    func restoredOnFromDefaults() {
        let arming = PrivateCloudArming(isOn: true)
        #expect(arming.isOn)
        #expect(arming.action(in: chatA, control: .ready, hasAttachments: false) == .askConsent)
    }

    @Test("picked, the first send asks for consent")
    func firstSendAsks() {
        var arming = PrivateCloudArming()
        arming.select(true)
        #expect(arming.action(in: chatA, control: .ready, hasAttachments: false) == .askConsent)
    }

    @Test("after consent, later sends skip the sheet with the same choice")
    func staysOnAfterConsent() {
        var arming = PrivateCloudArming()
        arming.select(true)
        arming.consented(includeConversation: true, in: chatA)
        #expect(arming.isOn)
        #expect(arming.action(in: chatA, control: .ready, hasAttachments: false) == direct)
        #expect(arming.action(in: chatA, control: .ready, hasAttachments: false) == direct)
    }

    @Test("\"Keep it on this Mac\" turns it off and forgets the consent")
    func declineTurnsOff() {
        var arming = PrivateCloudArming()
        arming.select(true)
        arming.declined()
        #expect(!arming.isOn)
        arming.select(true)
        #expect(arming.action(in: chatA, control: .ready, hasAttachments: false) == .askConsent)
    }

    @Test("picking a brain on this Mac turns it off; picking PCC again asks again")
    func pickingLocalForgetsConsent() {
        var arming = PrivateCloudArming()
        arming.select(true)
        arming.consented(includeConversation: false, in: chatA)
        arming.select(false)
        #expect(!arming.isOn)
        arming.select(true)
        #expect(arming.action(in: chatA, control: .ready, hasAttachments: false) == .askConsent)
    }

    @Test("re-picking PCC while on keeps the conversation's consent")
    func reselectKeepsConsent() {
        var arming = PrivateCloudArming()
        arming.select(true)
        arming.consented(includeConversation: true, in: chatA)
        arming.select(true)
        #expect(arming.action(in: chatA, control: .ready, hasAttachments: false) == direct)
    }

    @Test("a new or switched conversation keeps PCC on but asks again: consent never crosses conversations")
    func conversationChangeKeepsPickForgetsConsent() {
        var arming = PrivateCloudArming()
        arming.select(true)
        arming.consented(includeConversation: true, in: chatA)
        arming.conversationChanged()
        #expect(arming.isOn)
        #expect(arming.action(in: chatA, control: .ready, hasAttachments: false) == .askConsent)
    }

    @Test("a passing outage or an exhausted limit keeps the pick; sends stay local until it's back")
    func transientControlKeepsPick() {
        for control: PrivateCloudRung.Control in [.unavailable, .exhausted(resetsAt: nil)] {
            var arming = PrivateCloudArming()
            arming.select(true)
            arming.consented(includeConversation: true, in: chatA)
            arming.controlChanged(control)
            #expect(arming.isOn)
            #expect(arming.action(in: chatA, control: control, hasAttachments: false) == .local)
            #expect(!arming.servesNextSend(control: control, hasAttachments: false))
            arming.controlChanged(.ready)
            #expect(arming.action(in: chatA, control: .ready, hasAttachments: false) == direct)
        }
    }

    @Test("a rung that no longer exists (Settings switch off, org policy) turns it off")
    func hiddenControlTurnsOff() {
        var arming = PrivateCloudArming()
        arming.select(true)
        arming.consented(includeConversation: true, in: chatA)
        arming.controlChanged(.hidden)
        #expect(!arming.isOn)
    }

    @Test("a staged attachment keeps the pick, but that send stays on this Mac")
    func attachmentSendsLocal() {
        var arming = PrivateCloudArming()
        arming.select(true)
        arming.consented(includeConversation: true, in: chatA)
        #expect(arming.action(in: chatA, control: .ready, hasAttachments: true) == .local)
        #expect(!arming.servesNextSend(control: .ready, hasAttachments: true))
        #expect(arming.isOn)
        #expect(arming.action(in: chatA, control: .ready, hasAttachments: false) == direct)
    }

    /// Review of the 10-01 change: the pick now survives a conversation switch,
    /// so a sheet answered for A while B became active must not leave B with a
    /// consent it never saw — B's first send still asks.
    @Test("a consent given for one conversation never lets another skip the sheet")
    func consentIsBoundToItsConversation() {
        var arming = PrivateCloudArming()
        arming.select(true)
        arming.conversationChanged() // A → B under an open sheet
        arming.consented(includeConversation: true, in: chatA) // the sheet answers for A
        #expect(arming.action(in: chatB, control: .ready, hasAttachments: false) == .askConsent)
        #expect(arming.action(in: chatA, control: .ready, hasAttachments: false) == direct)
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
