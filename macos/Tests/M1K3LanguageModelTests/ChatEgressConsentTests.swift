//
//  ChatEgressConsentTests.swift
//  M1K3LanguageModelTests
//
//  Pins the dedicated chat-egress consent (Phase 17a): the ladder's
//  `networkAllowed` gate resolves from ITS OWN default-OFF key, never from the
//  web-search toggle (which defaults ON and governs web TOOLS, a different
//  egress category). An absent value is a NO — consent is given, never assumed.
//
//  Signed: Kev + claude-fable-5, 2026-07-08, Confidence 0.9 (the default-OFF
//  semantics are the whole point of the seam; challenger finding folded).
//  Prior: Unknown
//

import Foundation
@testable import M1K3LanguageModel
import SwiftUI // AppStorage: the views' own reading of the key
import Testing

struct ChatEgressConsentTests {
    /// A private defaults domain per test — the suite runs in parallel, and the
    /// real standard domain must never be touched by a test.
    private static func scratchDefaults() -> (UserDefaults, String) {
        let suite = "m1k3.test.egress.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test("persisted: an absent key is 'never answered', not false")
    func persistedAbsentIsNil() {
        let (defaults, suite) = Self.scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ChatEgressConsent.persisted(in: defaults) == nil)
    }

    @Test("persisted: a stored Bool reads back as itself")
    func persistedBool() {
        let (defaults, suite) = Self.scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: ChatEgressConsent.defaultsKey)
        #expect(ChatEgressConsent.persisted(in: defaults) == true)
        defaults.set(false, forKey: ChatEgressConsent.defaultsKey)
        #expect(ChatEgressConsent.persisted(in: defaults) == false)
    }

    /// A launch argument (`-chatEgressAllowed YES`), `defaults write -string` or a
    /// profile can store a string. The views read the key through @AppStorage;
    /// a send-time `as? Bool` read got nil where the view read true, and refused
    /// a send the UI had offered (seen live 2026-09-14). So the gate's reading is
    /// pinned against SwiftUI's own, not against another UserDefaults call: if
    /// @AppStorage's coercion ever changes, this goes red, not the consent gate.
    enum Stored: CaseIterable {
        case absent, boolTrue, boolFalse, yes, no, trueWord, one, zero

        func write(to defaults: UserDefaults, key: String) {
            switch self {
            case .absent: break
            case .boolTrue: defaults.set(true, forKey: key)
            case .boolFalse: defaults.set(false, forKey: key)
            case .yes: defaults.set("YES", forKey: key)
            case .no: defaults.set("NO", forKey: key)
            case .trueWord: defaults.set("true", forKey: key)
            case .one: defaults.set("1", forKey: key)
            case .zero: defaults.set("0", forKey: key)
            }
        }
    }

    @Test("persisted agrees with the views' @AppStorage for every stored shape", arguments: Stored.allCases)
    func persistedMatchesAppStorage(stored: Stored) {
        let (defaults, suite) = Self.scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        stored.write(to: defaults, key: ChatEgressConsent.defaultsKey)
        let view = AppStorage(wrappedValue: false, ChatEgressConsent.defaultsKey, store: defaults)
        #expect(ChatEgressConsent.networkAllowed(persisted: ChatEgressConsent.persisted(in: defaults))
            == view.wrappedValue)
    }

    @Test("no stored value means NO — consent is never assumed")
    func absentIsDenied() {
        #expect(ChatEgressConsent.networkAllowed(persisted: nil) == false)
    }

    @Test("an explicit false stays false")
    func explicitFalseDenied() {
        #expect(ChatEgressConsent.networkAllowed(persisted: false) == false)
    }

    @Test("only an explicit true opens the gate")
    func explicitTrueAllows() {
        #expect(ChatEgressConsent.networkAllowed(persisted: true) == true)
    }

    @Test("the gate feeds the ladder: no consent → a PCC escalation resolves local")
    func deniedGateKeepsEscalationLocal() {
        let floor = LanguageModelDescriptor(
            id: "lil-4b", reach: .onDevice, capabilities: [.toolCalling],
            requiresAppleIntelligence: false, isLocalFloor: true
        )
        let pcc = LanguageModelDescriptor(
            id: "apple-pcc", reach: .privateCloud, capabilities: [.toolCalling]
        )
        let context = LadderContext(
            appleIntelligenceAvailable: true,
            networkAllowed: ChatEgressConsent.networkAllowed(persisted: nil),
            userEscalation: .privateCloud
        )
        let pick = EscalationLadder.select(context, from: [floor, pcc])
        #expect(pick?.id == "lil-4b")
    }
}
