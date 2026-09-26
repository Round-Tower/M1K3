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
//

import Foundation

public struct PrivateCloudArming: Equatable, Sendable {
    /// What a send does right now.
    public enum Action: Equatable, Sendable {
        case local
        case askConsent
        case sendDirect(includeConversation: Bool)
    }

    public private(set) var isOn = false
    /// The sheet's answer for this conversation; nil until the user has sent once.
    private var consent: Bool?

    public init() {}

    public func action(control: PrivateCloudRung.Control, hasAttachments: Bool) -> Action {
        guard isOn, control == .ready, !hasAttachments else { return .local }
        return consent.map { .sendDirect(includeConversation: $0) } ?? .askConsent
    }

    /// The control's click. Off always forgets the consent, so on-again asks again.
    public mutating func toggle() {
        if isOn { turnOff() } else { isOn = true }
    }

    public mutating func consented(includeConversation: Bool) {
        guard isOn else { return }
        consent = includeConversation
    }

    /// "Keep it on this Mac" on the sheet.
    public mutating func declined() {
        turnOff()
    }

    public mutating func conversationChanged() {
        turnOff()
    }

    public mutating func controlChanged(_ control: PrivateCloudRung.Control) {
        if control != .ready { turnOff() }
    }

    public mutating func attachmentsStaged() {
        turnOff()
    }

    private mutating func turnOff() {
        isOn = false
        consent = nil
    }
}
