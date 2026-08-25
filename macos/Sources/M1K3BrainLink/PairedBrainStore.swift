//
//  PairedBrainStore.swift
//  M1K3BrainLink
//
//  Device-side persistence for the one paired Mac (v1 pairs with one):
//  metadata in UserDefaults, the PSK in the device Keychain — mirroring the
//  Mac side's split (devices list in defaults, keys in KeychainKeyStore).
//  The Keychain access is its own tiny portable SecItem wrapper because the
//  Mac's KeychainKeyStore lives in M1K3Calls, which the mobile shell
//  deliberately doesn't link.
//
//  Signed: Kev + claude-fable-5, 2026-08-24, Confidence 0.85 (store logic
//  test-pinned over an isolated suite + in-memory keys; the real Keychain
//  arm is verify-by-launch on device — same convention as the Mac's).
//  Prior: BrainServeController.swift (the persistence split).
//

import Foundation
import Security

public protocol BrainKeyStoring: Sendable {
    func setKey(_ key: Data, identity: String) throws
    func key(identity: String) -> Data?
    func removeKey(identity: String)
}

/// Generic-password Keychain storage, portable across macOS/iOS/visionOS.
/// afterFirstUnlock + this-device-only — the same posture as the Mac side.
public struct KeychainBrainKeyStore: BrainKeyStoring {
    static let service = "app.m1k3.brainlink"

    public init() {}

    public func setKey(_ key: Data, identity: String) throws {
        removeKey(identity: identity)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: identity,
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    public func key(identity: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: identity,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    public func removeKey(identity: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: identity,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// The one paired Mac. Metadata round-trips through UserDefaults; the
/// credential is only whole when BOTH halves exist (a lost Keychain row
/// reads as unpaired, never as a half-paired ghost).
/// @unchecked: UserDefaults is documented thread-safe; it just isn't marked.
public struct PairedBrainStore: @unchecked Sendable {
    public static let brainKey = "brainLink.pairedBrain"

    private let defaults: UserDefaults
    private let keys: any BrainKeyStoring

    public init(defaults: UserDefaults = .standard, keys: any BrainKeyStoring = KeychainBrainKeyStore()) {
        self.defaults = defaults
        self.keys = keys
    }

    public func save(_ brain: PairedBrain, key: Data) throws {
        try keys.setKey(key, identity: brain.identity)
        if let data = try? JSONEncoder().encode(brain) {
            defaults.set(data, forKey: Self.brainKey)
        }
    }

    /// Metadata-only rewrite (lastKnownHost updates) — the key stays put.
    public func update(_ brain: PairedBrain) {
        if let data = try? JSONEncoder().encode(brain) {
            defaults.set(data, forKey: Self.brainKey)
        }
    }

    public func load() -> PairedBrain? {
        guard let data = defaults.data(forKey: Self.brainKey) else { return nil }
        return try? JSONDecoder().decode(PairedBrain.self, from: data)
    }

    public func credential() -> PSKCredential? {
        guard let brain = load(), let key = keys.key(identity: brain.identity) else { return nil }
        return PSKCredential(identity: brain.identity, key: key)
    }

    public func forget() {
        if let brain = load() {
            keys.removeKey(identity: brain.identity)
        }
        defaults.removeObject(forKey: Self.brainKey)
    }
}
