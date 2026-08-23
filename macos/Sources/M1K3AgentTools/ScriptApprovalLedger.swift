//
//  ScriptApprovalLedger.swift
//  M1K3AgentTools
//
//  The inner consent boundary for the hands: a script runs only when the file
//  in the folder is byte-identical to what the user approved. Approval records
//  pin name → SHA-256 at install time (the RecordingConsent audit-trail
//  pattern); the verdict is pure so drift can never be argued with.
//
//  Signed: Kev + claude-fable-5, 2026-08-23, Confidence 0.9, Prior: Unknown

import Foundation

/// One logged approval: this name, these exact bytes, affirmed then.
public struct ScriptApproval: Sendable, Equatable, Codable {
    public let name: String
    public let sha256: String
    public let approvedAt: Date

    public init(name: String, sha256: String, approvedAt: Date) {
        self.name = name
        self.sha256 = sha256
        self.approvedAt = approvedAt
    }
}

/// Persists approvals. Seam so the tool and ledger are testable.
public protocol ScriptApprovalStoring: Sendable {
    func approvals() -> [ScriptApproval]
    /// Record (or replace, by name) an approval.
    func record(_ approval: ScriptApproval)
    /// Drop an approval — the script stops being runnable until re-approved.
    func revoke(name: String)
}

/// UserDefaults-backed approval store (the app default). JSON-encoded array
/// under one key. `@unchecked Sendable`: `UserDefaults` is documented
/// thread-safe.
public struct UserDefaultsScriptApprovalStore: ScriptApprovalStoring, @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "app.m1k3.scriptApprovals") {
        self.defaults = defaults
        self.key = key
    }

    public func approvals() -> [ScriptApproval] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([ScriptApproval].self, from: data)) ?? []
    }

    public func record(_ approval: ScriptApproval) {
        var all = approvals()
        all.removeAll { $0.name == approval.name }
        all.append(approval)
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: key)
        }
    }

    public func revoke(name: String) {
        let remaining = approvals().filter { $0.name != name }
        if let data = try? JSONEncoder().encode(remaining) {
            defaults.set(data, forKey: key)
        }
    }
}

/// The pure approval decision.
public enum ScriptApprovalLedger {
    public enum Verdict: Equatable, Sendable {
        /// Name and bytes match an approval — runnable.
        case approved
        /// No approval record exists for this name.
        case unknown
        /// The file's bytes differ from what was approved — refuse and name it.
        case drifted(approvedSHA256: String)
    }

    public static func verdict(
        name: String, sha256: String, approvals: [ScriptApproval]
    ) -> Verdict {
        guard let approval = approvals.first(where: { $0.name == name }) else {
            return .unknown
        }
        return approval.sha256 == sha256 ? .approved : .drifted(approvedSHA256: approval.sha256)
    }
}
