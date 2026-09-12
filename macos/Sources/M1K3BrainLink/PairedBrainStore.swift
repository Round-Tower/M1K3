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
//  Review: Kev + claude-fable-5.1, 2026-09-12 — the PSK row targets the data-protection
//  keychain (no per-binary login-password prompt on the Mac); a legacy row is lifted
//  across on first read. Confidence now 0.85.
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
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    public func key(identity: String) -> Data? {
        if let data = read(Self.query(identity: identity)) { return data }
        // A PSK written before 2026-09-12 sits in the Mac's login keychain
        // (a no-op distinction on iOS): lift it across once, then drop the old row.
        guard let legacy = read(Self.legacyQuery(identity: identity)) else { return nil }
        if (try? setKey(legacy, identity: identity)) != nil {
            _ = SecItemDelete(Self.legacyQuery(identity: identity) as CFDictionary)
        }
        return legacy
    }

    public func removeKey(identity: String) {
        _ = SecItemDelete(Self.query(identity: identity) as CFDictionary)
        _ = SecItemDelete(Self.legacyQuery(identity: identity) as CFDictionary)
    }

    private func read(_ base: [String: Any]) -> Data? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    /// Data-protection keychain: access by team + bundle id, so every build we
    /// sign reads the item silently (the Mac's login keychain asked for the
    /// login password per new signature). See M1K3Calls.KeychainKeyStore.
    static func query(identity: String) -> [String: Any] {
        var query = legacyQuery(identity: identity)
        query[kSecUseDataProtectionKeychain as String] = true
        return query
    }

    static func legacyQuery(identity: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: identity,
        ]
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
