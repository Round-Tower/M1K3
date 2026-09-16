//
//  OnboardingExperience.swift
//  M1K3Inference
//
//  The two-door onboarding choice (#363). M1K3's privacy promise means every
//  feature starts off — which means the person who trusts us enough to install
//  gets a stripped-down version they need to configure toggle by toggle. The
//  fix: one tap at first run that writes all the "on" defaults in one pass.
//
//  Pure and testable: the list of keys is the contract; the UI (HelloView)
//  calls `apply(to:)`. Keys match the app-target constants by string value
//  (they are stable — each is a persisted preference key that can never
//  change without a migration).
//

import Foundation

public enum OnboardingExperience: String, Sendable, CaseIterable {
    case fullExperience
    case privateByDefault

    public struct DefaultEntry: Equatable, Sendable {
        public let key: String
        public let value: Bool
    }

    /// The defaults "Full Experience" writes. Each key is the exact string
    /// the feature's `@AppStorage` / `UserDefaults.bool(forKey:)` reads.
    public static let fullExperienceDefaults: [DefaultEntry] = [
        DefaultEntry(key: "notchHUD.enabled", value: true),
        DefaultEntry(key: "heartbeat.enabled", value: true),
        DefaultEntry(key: "notifications.heartbeat", value: true),
        DefaultEntry(key: "contextTools.battery", value: true),
        DefaultEntry(key: "contextTools.calendar", value: true),
        DefaultEntry(key: "contextTools.location", value: true),
        DefaultEntry(key: "chatEgressAllowed", value: true),
    ]

    /// Write this experience's defaults into a store. `.privateByDefault`
    /// writes nothing — today's defaults are already off.
    public func apply(to defaults: UserDefaults) {
        switch self {
        case .fullExperience:
            for entry in Self.fullExperienceDefaults {
                defaults.set(entry.value, forKey: entry.key)
            }
        case .privateByDefault:
            break
        }
    }
}
