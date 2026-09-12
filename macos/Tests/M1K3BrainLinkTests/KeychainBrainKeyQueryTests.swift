//
//  KeychainBrainKeyQueryTests.swift
//  M1K3BrainLinkTests
//
//  Pins the one Keychain fact the adapter can prove without a Keychain: the
//  PSK row is addressed in the data-protection keychain (team + bundle id
//  access), not the Mac's login keychain (per-binary ACL → password prompts
//  for every freshly signed build). The legacy address is kept for the
//  one-time lift. 2026-09-12.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-12, Confidence 0.85, Prior: Unknown

import Foundation
@testable import M1K3BrainLink
import Security
import Testing

struct KeychainBrainKeyQueryTests {
    @Test("the PSK row lives in the data-protection keychain")
    func dataProtection() {
        let query = KeychainBrainKeyStore.query(identity: "abc")
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect(query[kSecAttrService as String] as? String == "app.m1k3.brainlink")
        #expect(query[kSecAttrAccount as String] as? String == "abc")
    }

    @Test("the legacy address is the same row without the flag")
    func legacy() {
        let legacy = KeychainBrainKeyStore.legacyQuery(identity: "abc")
        #expect(legacy[kSecUseDataProtectionKeychain as String] == nil)
        #expect(legacy[kSecAttrAccount as String] as? String == "abc")
    }
}
