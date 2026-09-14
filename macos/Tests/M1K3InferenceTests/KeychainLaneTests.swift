//
//  KeychainLaneTests.swift
//  M1K3InferenceTests
//
//  Which keychain this process can use (#319). The data-protection keychain needs
//  an application-identifier entitlement that only a provisioned build carries;
//  the Developer ID lane (nightly DMG, Homebrew cask) has none and every query
//  there fails with errSecMissingEntitlement (-34018). The lane is decided once,
//  from one probe, and every key store builds its queries through it.
//
//  Signed: Kev + claude-opus-5, 2026-09-14, Confidence 0.85. Prior: none (new file).
//

import Foundation
import M1K3Inference
import Security
import Testing

struct KeychainLaneTests {
    @Test("a probe that reached the data-protection keychain keeps it")
    func reachableKeepsDataProtection() {
        #expect(KeychainLane.resolve(probeStatus: errSecItemNotFound) == .dataProtection)
        #expect(KeychainLane.resolve(probeStatus: errSecSuccess) == .dataProtection)
    }

    @Test("a missing entitlement falls back to the login keychain")
    func missingEntitlementFallsBack() {
        #expect(errSecMissingEntitlement == -34018)
        #expect(KeychainLane.resolve(probeStatus: errSecMissingEntitlement) == .login)
    }

    @Test("any other probe failure keeps data protection (a locked keychain is not a missing entitlement)")
    func otherFailuresKeepDataProtection() {
        #expect(KeychainLane.resolve(probeStatus: errSecInteractionNotAllowed) == .dataProtection)
    }

    @Test("the data-protection lane marks the query; the login lane leaves it bare")
    func applyingMarksOnlyDataProtection() {
        let base: [String: Any] = [kSecAttrAccount as String: "k"]
        let marked = KeychainLane.dataProtection.applying(to: base)
        #expect(marked[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(marked[kSecAttrAccount as String] as? String == "k")
        let bare = KeychainLane.login.applying(to: base)
        #expect(bare[kSecUseDataProtectionKeychain as String] == nil)
        #expect(bare[kSecAttrAccount as String] as? String == "k")
    }
}
