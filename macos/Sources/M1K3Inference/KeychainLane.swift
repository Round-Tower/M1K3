//
//  KeychainLane.swift
//  M1K3Inference
//
//  Which keychain this process can use — a platform fact, like HostPlatform.
//  The data-protection keychain (access by team + bundle id, no per-binary
//  login-password prompt) needs an application-identifier entitlement that only
//  a provisioned build carries: App Store, TestFlight, a debug ⌘R. The Developer
//  ID lane (nightly DMG, Homebrew cask) has no profile, and every data-protection
//  query there fails with errSecMissingEntitlement (-34018, #319). Those builds
//  use the login keychain, as every build did before 2026-09-12, prompt and all.
//
//  One probe per process: a read of an account that never exists. It returns
//  errSecItemNotFound where the entitlement is present and never prompts.
//
//  Signed: Kev + claude-opus-5, 2026-09-14, Confidence 0.85 (the mapping is
//  pinned; that the probe reads -34018 on the Developer ID build is from the
//  #319 log, re-checked by launch). Prior: none (new file).
//

import Foundation
import Security

public enum KeychainLane: Sendable, Equatable {
    /// The data-protection keychain: provisioned builds, and every iOS build.
    case dataProtection
    /// The login keychain: Developer ID builds with no application identifier.
    case login

    /// Only a missing entitlement changes the lane. A locked keychain or any
    /// other failure is not evidence the lane is unusable, so it stays put.
    public static func resolve(probeStatus: OSStatus) -> KeychainLane {
        probeStatus == errSecMissingEntitlement ? .login : .dataProtection
    }

    /// This process's lane, probed once on first use. The first touch is the
    /// call store's setup on the main actor, beside the key reads it already
    /// makes there; the probe reads a never-written item and returns at once.
    public static let current: KeychainLane = resolve(probeStatus: probe())

    /// Marks a query for the data-protection keychain; the login lane leaves it bare.
    public func applying(to query: [String: Any]) -> [String: Any] {
        guard self == .dataProtection else { return query }
        var marked = query
        marked[kSecUseDataProtectionKeychain as String] = true
        return marked
    }

    private static func probe() -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.m1k3.keychain-lane-probe",
            kSecAttrAccount as String: "probe",
            kSecUseDataProtectionKeychain as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil)
    }
}
