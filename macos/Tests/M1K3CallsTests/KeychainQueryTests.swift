//
//  KeychainQueryTests.swift
//  M1K3CallsTests
//
//  The one thing about the Keychain adapter that CAN be pinned without the
//  Keychain: the query it builds. Every item goes to the data-protection
//  keychain, where access is by team + bundle identifier — not the login
//  keychain, whose per-binary ACL asks for the login password every time a
//  freshly signed build (a test host, a SelfTest run, a debug ⌘R) touches an
//  item the shipping app wrote (2026-09-12, Kev's screenshot).
//
//  Signed: Kev + claude-fable-5.1, 2026-09-12, Confidence 0.85 (the flag is
//  pinned here; that it stops the prompt is verify-by-launch), Prior: Unknown

import Foundation
@testable import M1K3Calls
import Security
import Testing

struct KeychainQueryTests {
    @Test("every query targets the data-protection keychain")
    func dataProtectionKeychain() {
        let query = KeychainKeyStore.query(service: "app.m1k3", account: "k")
        #expect(query[kSecUseDataProtectionKeychain] as? Bool == true)
        #expect(query[kSecAttrService] as? String == "app.m1k3")
        #expect(query[kSecAttrAccount] as? String == "k")
    }

    @Test("the legacy query is the same item in the login keychain")
    func legacyQuery() {
        let legacy = KeychainKeyStore.legacyQuery(service: "app.m1k3", account: "k")
        #expect(legacy[kSecUseDataProtectionKeychain] == nil)
        #expect(legacy[kSecAttrService] as? String == "app.m1k3")
        #expect(legacy[kSecAttrAccount] as? String == "k")
    }
}
