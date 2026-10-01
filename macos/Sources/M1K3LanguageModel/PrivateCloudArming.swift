//
//  PrivateCloudArming.swift
//  M1K3LanguageModel
//
//  The brain picker's Private Cloud Compute pick, and its consent, as pure
//  state (ADR 0010, current contract). The pick and the sheet's one answer
//  persist (the view writes `selectedDefaultsKey` / `consentDefaultsKey`) and
//  hold across conversations and relaunches until the user un-picks PCC, says
//  "Keep it on this Mac", or the rung stops existing — each of which forgets
//  the answer. One exception keeps "you see what leaves" true: with "also
//  send this conversation" stored, any message that never left this Mac
//  (`ChatSession.onDeviceMessageIDs`) re-asks until a sheet has shown it.
//  What was shown is never persisted. Sends that can't be honoured
//  (outage, limit, attachment) stay local while the pick holds.
//
//  History: 09-26 made it stay on per conversation (in view state, never in
//  defaults); the reviews below moved it to the picker and to once.
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
//  Review: Kev + claude-opus-5-5, 2026-10-01 (4) — PR #462 round two (both passes): clearing a whole
//  conversation went stale when a local turn landed after the sheet (attachment, outage, voice), and
//  that answer then left unseen. Now by message id: the sheet records the on-device ids it showed and
//  any unseen id re-asks. The header above is rewritten to the current contract. Confidence 0.85.
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
    /// Ids of the on-device messages a sheet has shown. Never persisted: a
    /// relaunch asks again where it matters.
    private var seenOnDevice: Set<UUID> = []

    /// `isOn` and `consent` are the persisted pick and answer.
    public init(isOn: Bool = false, consent: Bool? = nil) {
        self.isOn = isOn
        self.consent = isOn ? consent : nil
    }

    /// What a send does right now. `onDeviceMessages`: the ids in the history
    /// PCC would be shown that never left this Mac.
    public func action(
        control: PrivateCloudRung.Control,
        hasAttachments: Bool,
        onDeviceMessages: Set<UUID>
    ) -> Action {
        guard servesNextSend(control: control, hasAttachments: hasAttachments) else { return .local }
        guard let includeConversation = consent else { return .askConsent }
        // Once means once — except that text which never left this Mac is never
        // sent without a sheet having shown it. By message, not conversation: a
        // local turn landing after the sheet (attachment, outage, voice) re-asks.
        if includeConversation, !onDeviceMessages.isSubset(of: seenOnDevice) {
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

    /// The sheet's yes. `seen`: the on-device message ids it showed, captured
    /// when it opened (so a sheet answered after a switch clears only those).
    public mutating func consented(includeConversation: Bool, seen: Set<UUID>) {
        guard isOn else { return }
        consent = includeConversation
        if includeConversation { seenOnDevice.formUnion(seen) }
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
        seenOnDevice = []
    }
}
