//
//  PrivateCloudArming.swift
//  M1K3LanguageModel
//
//  The PCC control's lifecycle as pure state. It used to arm ONE message and
//  fall back to local after every send, so a cloud conversation meant a click
//  and a sheet per turn (Kev, 2026-09-26: "PCC should stay on when selected").
//  Now it stays on for the conversation: the consent sheet shows on the first
//  send, and later sends go straight to PCC with the same include-conversation
//  choice. Each PCC answer still carries its label (ADR 0006, as amended).
//
//  It turns itself off whenever the consent could be stale or can't be
//  honoured: "Keep it on this Mac", a manual off, a new or switched
//  conversation, a control that isn't ready, or a staged attachment. Consent
//  never outlives the conversation it was given in, and a relaunch starts off
//  (the value lives in view state, never in defaults).
//
//  Signed: Kev + claude-opus-5-5, 2026-09-26, Confidence 0.8 (pure and pinned;
//  the ADR 0006 amendment it implements awaits Kev). Prior: the one-shot
//  `privateCloudArmed` Bool in ContentView.
//  Review: Kev + claude-opus-5-5, 2026-10-01 — PCC moved into the brain picker
//  and HOLDS over time (Kev: "PCC moved to the brain picker - holds over time").
//  The pick is persisted (`selectedDefaultsKey`, restored via `init(isOn:)`) and
//  survives a conversation change, a passing outage, an exhausted limit and a
//  staged attachment — those sends stay local while the pick waits. Only the
//  user ends it: picking a brain on this Mac, or "Keep it on this Mac"; a rung
//  that no longer exists (Settings switch off, org policy) ends it too. What
//  did NOT change: consent is still per conversation — the first PCC send in
//  each one shows the sheet, because its include-the-conversation answer is
//  about that conversation. The paragraph above is the 09-26 contract this
//  replaces. Confidence 0.8 (pure and pinned; the menu is verify-by-launch).
//  Review: Kev + claude-opus-5-5, 2026-10-01 (2) — code-quality review fold: consent carries its
//  conversation id. With the pick surviving a switch, a sheet answered for A after B became
//  active used to arm B with no sheet. `action(in:)` asks again unless the ids match. Pinned.
//  Confidence 0.85.
//  Review: Kev + claude-opus-5-5, 2026-10-01 (3) — consent is asked ONCE (Kev: "I think it should be
//  once"), not per conversation: the sheet's answer persists with the pick and dies with it. The one
//  exception: with "also send this conversation" stored, a conversation holding on-device answers
//  shows the sheet once itself — history that never left this Mac never leaves unseen. That set of
//  cleared conversations is never persisted. Supersedes (2)'s per-conversation binding. Confidence 0.85.
//

import Foundation

public struct PrivateCloudArming: Equatable, Sendable {
    /// The persisted pick: the brain picker's PCC row survives a relaunch.
    public static let selectedDefaultsKey = "privateCloudSelected"
    /// The persisted sheet answer — its "also send this conversation" choice.
    /// Absent until the user has confirmed the sheet once; cleared with the pick.
    public static let consentDefaultsKey = "privateCloudConsentIncludesConversation"

    /// What a send does right now.
    public enum Action: Equatable, Sendable {
        case local
        case askConsent
        case sendDirect(includeConversation: Bool)
    }

    /// The user picked PCC in the brain picker. Not the same as "the next send
    /// goes to PCC" — that's `servesNextSend`.
    public private(set) var isOn: Bool
    /// The sheet's one answer (include the conversation?), nil until confirmed.
    /// Persisted by the view; it lives exactly as long as the pick.
    public private(set) var consent: Bool?
    /// Conversations whose on-device history the user has seen leave on the
    /// sheet. Never persisted: a relaunch asks again where it matters.
    private var historyCleared: Set<UUID> = []

    /// `isOn` and `consent` are the persisted pick and answer.
    public init(isOn: Bool = false, consent: Bool? = nil) {
        self.isOn = isOn
        self.consent = isOn ? consent : nil
    }

    /// What a send in `conversationID` does right now. `holdsOnDeviceAnswers`:
    /// the history PCC would be shown includes answers made on this Mac.
    public func action(
        in conversationID: UUID,
        control: PrivateCloudRung.Control,
        hasAttachments: Bool,
        holdsOnDeviceAnswers: Bool
    ) -> Action {
        guard servesNextSend(control: control, hasAttachments: hasAttachments) else { return .local }
        guard let includeConversation = consent else { return .askConsent }
        // Once means once — except that history which never left this Mac is
        // never sent without the user seeing it go, once per conversation.
        if includeConversation, holdsOnDeviceAnswers, !historyCleared.contains(conversationID) {
            return .askConsent
        }
        return .sendDirect(includeConversation: includeConversation)
    }

    /// True when the next send would leave for PCC — what the brain picker's
    /// label shows, so it never claims PCC for a send that stays on this Mac.
    public func servesNextSend(control: PrivateCloudRung.Control, hasAttachments: Bool) -> Bool {
        isOn && control == .ready && !hasAttachments
    }

    /// The brain picker: true = the PCC row, false = a brain on this Mac. Off
    /// always forgets the consent, so on-again asks again; re-picking PCC
    /// while it's on keeps it.
    public mutating func select(_ on: Bool) {
        if on { isOn = true } else { turnOff() }
    }

    /// The sheet's yes, given in `conversationID` (where it was opened, which
    /// may no longer be the active one).
    public mutating func consented(includeConversation: Bool, in conversationID: UUID) {
        guard isOn else { return }
        consent = includeConversation
        historyCleared.insert(conversationID)
    }

    /// "Keep it on this Mac" on the sheet.
    public mutating func declined() {
        turnOff()
    }

    /// A passing outage or an exhausted limit keeps the pick (`action` stays
    /// local meanwhile); a rung that no longer exists ends it.
    public mutating func controlChanged(_ control: PrivateCloudRung.Control) {
        if control == .hidden { turnOff() }
    }

    private mutating func turnOff() {
        isOn = false
        consent = nil
        historyCleared = []
    }
}
