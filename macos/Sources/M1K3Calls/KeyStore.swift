//
//  KeyStore.swift
//  M1K3Calls
//
//  The low-level secret-storage seam: bytes in/out by account. A protocol so the
//  key-management LOGIC (StoredKeyProvider) is testable against a fake, while the
//  real Keychain access lives in one thin, verify-by-launch adapter. Mirrors the
//  pattern used everywhere in M1K3 — isolate the OS dependency behind a seam.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-09-12 — every query targets the data-protection
//  keychain (team + bundle id access, no per-binary login-password prompt); a miss
//  lifts the legacy login-keychain item across once. Confidence now 0.85.

import Foundation
import Security

public protocol KeyStore: Sendable {
    func data(forAccount account: String) throws -> Data?
    func setData(_ data: Data, forAccount account: String) throws
    func removeData(forAccount account: String) throws
}

public enum KeyStoreError: Error, Sendable, Equatable {
    case unexpectedStatus(OSStatus)
    case accessControlUnavailable
    /// The user dismissed the biometric (Touch ID) sheet. Distinct from a real
    /// failure so the caller can tell "couldn't unlock" from "wouldn't unlock."
    case userCancelled
}

/// Keychain-backed secret storage (generic-password items). Device-only and only
/// readable after first unlock — never synced to iCloud — matching M1K3's
/// privacy-first stance. Thin OS adapter: verified by launching the app, not by
/// `swift test` (the logic that uses it is tested via the in-memory fake).
public struct KeychainKeyStore: KeyStore {
    /// How the OS guards the item at rest.
    public enum Protection: Sendable {
        /// Readable after first device unlock, no user interaction. The original
        /// behaviour — used where the secret must be available unattended.
        case afterFirstUnlock
        /// Gated behind the user's presence: Touch ID, with the login password as
        /// the system fallback. Reading the item presents the system biometric
        /// sheet automatically (the access control is what triggers it). Device-
        /// only, never synced. This is what protects the call-encryption key.
        case userPresence
    }

    private let service: String
    private let protection: Protection

    public init(service: String = "app.m1k3", protection: Protection = .afterFirstUnlock) {
        self.service = service
        self.protection = protection
    }

    public func data(forAccount account: String) throws -> Data? {
        // For a `.userPresence` item this read is what surfaces the Touch ID sheet
        // (the item's access control drives it) — no LAContext needed for the
        // once-per-launch read the call store performs.
        if let data = try read(baseQuery(account)) { return data }
        return try migrateLegacyItem(account)
    }

    private func read(_ base: [CFString: Any]) throws -> Data? {
        var query = base
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: return item as? Data
        case errSecItemNotFound: return nil
        case errSecUserCanceled: throw KeyStoreError.userCancelled
        default: throw KeyStoreError.unexpectedStatus(status)
        }
    }

    /// Items written before 2026-09-12 live in the login keychain. On the first
    /// miss in the data-protection keychain, lift the legacy item across (its
    /// last login-password prompt) and delete the old row so it never asks again.
    private func migrateLegacyItem(_ account: String) throws -> Data? {
        guard let data = try read(Self.legacyQuery(service: service, account: account)) else { return nil }
        try setData(data, forAccount: account)
        _ = SecItemDelete(Self.legacyQuery(service: service, account: account) as CFDictionary)
        return data
    }

    public func setData(_ data: Data, forAccount account: String) throws {
        switch protection {
        case .afterFirstUnlock:
            // Upsert: update an existing item, else add a new one.
            let update = SecItemUpdate(
                baseQuery(account) as CFDictionary,
                [kSecValueData: data] as CFDictionary
            )
            if update == errSecSuccess { return }
            guard update == errSecItemNotFound else { throw KeyStoreError.unexpectedStatus(update) }

            var item = baseQuery(account)
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            try insert(item)

        case .userPresence:
            // SecItemUpdate can't add/replace an access control, so a biometric
            // write is delete-then-add. Deleting a `.userPresence` item does NOT
            // prompt (only reads do), so re-protecting an existing key is silent.
            //
            // Build the access control BEFORE the destructive delete — if it can't
            // be created we must not have already thrown away the existing key. And
            // if the add fails after the delete (the one window where the key bytes
            // would be lost, taking every encrypted call with them), roll back by
            // re-storing under the unprotected policy. Better an unprotected key
            // than an unrecoverable one; the next launch re-attempts the upgrade.
            let control = try userPresenceAccessControl()
            try removeData(forAccount: account)
            var item = baseQuery(account)
            item[kSecValueData] = data
            item[kSecAttrAccessControl] = control
            do {
                try insert(item)
            } catch {
                var fallback = baseQuery(account)
                fallback[kSecValueData] = data
                fallback[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                try? insert(fallback)
                throw error
            }
        }
    }

    private func insert(_ item: [CFString: Any]) throws {
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyStoreError.unexpectedStatus(status) }
    }

    /// `.userPresence` = biometry (Touch ID) OR device passcode fallback, on this
    /// device only. The access control the OS enforces on every read of the item.
    private func userPresenceAccessControl() throws -> SecAccessControl {
        var error: Unmanaged<CFError>?
        guard let control = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .userPresence,
            &error
        ) else {
            error?.release() // own + free the CFError on the failure path
            throw KeyStoreError.accessControlUnavailable
        }
        return control
    }

    public func removeData(forAccount account: String) throws {
        // A legacy row that was never lifted must not outlive a forget.
        _ = SecItemDelete(Self.legacyQuery(service: service, account: account) as CFDictionary)
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyStoreError.unexpectedStatus(status)
        }
    }

    private func baseQuery(_ account: String) -> [CFString: Any] {
        Self.query(service: service, account: account)
    }

    /// The data-protection keychain (iOS-style; on macOS opt-in since 10.15):
    /// access is decided by the app's team + bundle identifier, so every build
    /// we sign — the shipping app, a test host, SelfTest, a debug ⌘R — reads
    /// the same items silently. The login keychain's per-binary ACL asked for
    /// the login PASSWORD on each new signature (2026-09-12). It is also the
    /// only keychain that honours `kSecAttrAccessible*ThisDeviceOnly`.
    static func query(service: String, account: String) -> [CFString: Any] {
        var query = legacyQuery(service: service, account: account)
        query[kSecUseDataProtectionKeychain] = true
        return query
    }

    /// The same item as it was addressed before 2026-09-12 (login keychain).
    static func legacyQuery(service: String, account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
    }
}
