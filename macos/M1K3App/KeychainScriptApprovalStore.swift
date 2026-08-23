//
//  KeychainScriptApprovalStore.swift
//  M1K3App
//
//  Finding 3: the approval ledger is the ENTIRE trust boundary between "M1K3
//  proposed, the user clicked Install" and "arbitrary code runs" — so it must
//  not live in a plist any co-resident process can rewrite with `defaults
//  write`. This backs `ScriptApprovalStoring` with the Keychain (generic
//  password, device-only, afterFirstUnlock), whose per-app ACL means another
//  app signed by another team cannot forge an approval. Reuses M1K3Calls'
//  KeychainKeyStore (the same adapter Brain at Home's PSKs use). A one-time
//  migration lifts any approvals an older build wrote to UserDefaults, then
//  clears them so the weaker copy doesn't linger.
//
//  Signed: Kev + claude-fable-5, 2026-08-23, Confidence 0.8 (Keychain adapter
//  is verify-by-launch per M1K3's standing rule; the encode/verdict logic is
//  the same test-pinned ScriptApprovalLedger). Prior: Unknown.

import Foundation
import M1K3AgentTools
import M1K3Calls
import M1K3LogCore

/// Keychain-backed approval ledger. Plain `Sendable`: its one stored property
/// is an immutable `any KeyStore` (itself `Sendable`), so the compiler verifies
/// the conformance — no `@unchecked` to hide a future mutable field on the type
/// the header calls "the ENTIRE trust boundary".
struct KeychainScriptApprovalStore: ScriptApprovalStoring {
    private static let log = M1K3Log.logger(.scriptRun)
    private static let account = "scriptApprovals"

    private let keyStore: any KeyStore

    init(keyStore: any KeyStore = KeychainKeyStore(protection: .afterFirstUnlock)) {
        self.keyStore = keyStore
    }

    func approvals() -> [ScriptApproval] {
        guard let data = try? keyStore.data(forAccount: Self.account) ?? nil else { return [] }
        return (try? JSONDecoder().decode([ScriptApproval].self, from: data)) ?? []
    }

    func record(_ approval: ScriptApproval) {
        var all = approvals()
        all.removeAll { $0.name == approval.name }
        all.append(approval)
        persist(all)
    }

    func revoke(name: String) {
        persist(approvals().filter { $0.name != name })
    }

    private func persist(_ approvals: [ScriptApproval]) {
        guard let data = try? JSONEncoder().encode(approvals) else { return }
        do {
            try keyStore.setData(data, forAccount: Self.account)
        } catch {
            // Never silently downgrade to the tamperable store: a failed write
            // means the approval didn't stick, and the tool will refuse the run
            // (unknown verdict) — fail closed, and say why.
            Self.log.error("script approval keychain write failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Lift any approvals a pre-Keychain build left in UserDefaults into the
    /// Keychain once, then clear the plist copy. Idempotent.
    func migrateFromUserDefaultsIfNeeded(_ defaults: UserDefaults = .standard) {
        let legacyKey = "app.m1k3.scriptApprovals"
        guard let legacy = defaults.data(forKey: legacyKey),
              let decoded = try? JSONDecoder().decode([ScriptApproval].self, from: legacy),
              !decoded.isEmpty
        else { return }
        var merged = approvals()
        for approval in decoded where !merged.contains(where: { $0.name == approval.name }) {
            merged.append(approval)
        }
        persist(merged)
        defaults.removeObject(forKey: legacyKey)
        Self.log.notice("migrated \(decoded.count) script approval(s) from UserDefaults to Keychain")
    }
}
