//
//  CLITokenStore.swift
//  m1k3
//
//  Where `m1k3 login` keeps M1K3's access token (#270 slice 3): one generic-
//  password item in the login keychain, created by this binary, so its ACL
//  trusts this binary and any other reader gets the system's "allow?" prompt.
//  The login keychain, not the data-protection one: that needs an
//  application-identifier entitlement neither CLI lane carries (see
//  KeychainLane). Its own service, never the app's — the app's item is the
//  app's, and the CLI never reads it.
//
//  Thin OS adapter, verify-by-run (both lanes: the sandboxed App Store helper
//  and the Developer ID one). The token's shape is judged in M1K3CLICore.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-28, Confidence 0.8 (the Security
//  calls are the documented generic-password shape; driven live on the
//  sandboxed helper in the PR). Prior: none (new file).
//

import Foundation
import Security

enum CLITokenStore {
    static let service = "app.m1k3.cli"
    static let account = "mcp-access-token"

    struct Failure: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String {
            let reason = SecCopyErrorMessageString(status, nil).map { $0 as String } ?? "OSStatus \(status)"
            return "couldn't save the token in your keychain (\(reason))"
        }
    }

    private static var baseQuery: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
    }

    /// The saved token, or nil when there is none (or it can't be read — a
    /// call without a token then gets the door's 401 and its hint).
    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData] = kCFBooleanTrue
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Upsert: a second login replaces the first (a rotated token).
    static func save(_ token: String) throws {
        let data = Data(token.utf8)
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Failure(status: update) }
        var item = baseQuery
        item[kSecValueData] = data
        item[kSecAttrLabel] = "M1K3 access token (m1k3 CLI)"
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure(status: added) }
    }
}
