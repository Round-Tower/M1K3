//
//  OnboardingExperience.swift
//  M1K3Inference
//
//  The two-door onboarding choice (#363, #540). M1K3's privacy promise means
//  every feature starts off — which means the person who trusts us enough to
//  install gets a stripped-down version they need to configure toggle by toggle.
//  The fix: one tap at first run that writes all the "on" defaults in one pass.
//  The doors are symmetric: Full writes everything on, Private writes everything
//  off — so a re-run through either door is a true toggle.
//
//  Three of the seven keys need a real system setter (TCC dialog or notification
//  auth); `permissionRequiredKeys` names them so the UI can run the ceremony
//  instead of writing them directly.
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

    /// The three keys that need a system setter (TCC dialog or notification
    /// authorization) rather than a direct `UserDefaults` write. The UI runs
    /// the permission ceremony for these; `apply(to:)` still writes them as
    /// a baseline so Private always turns them off.
    public static let permissionRequiredKeys: Set<String> = [
        "contextTools.calendar",
        "contextTools.location",
        "notifications.heartbeat",
    ]

    /// Write this experience's defaults into a store. Both doors write
    /// their keys — Full writes `true`, Private writes `false` — so the
    /// doors are a true toggle on a re-run.
    ///
    /// Full skips the three permission-required keys (calendar, location,
    /// heartbeat notifications) so the UI's ceremony owns them via real
    /// setters. Private writes them `false` directly (turning off never
    /// needs a system prompt).
    public func apply(to defaults: UserDefaults) {
        let on = self == .fullExperience
        for entry in Self.fullExperienceDefaults {
            if on, Self.permissionRequiredKeys.contains(entry.key) { continue }
            defaults.set(on ? entry.value : false, forKey: entry.key)
        }
    }
}
