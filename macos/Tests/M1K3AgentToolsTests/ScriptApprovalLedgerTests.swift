//
//  ScriptApprovalLedgerTests.swift
//  M1K3AgentToolsTests
//
//  Signed: Kev + claude-fable-5, 2026-08-23, Confidence 0.9, Prior: Unknown

import Foundation
@testable import M1K3AgentTools
import Testing

struct ScriptApprovalLedgerTests {
    private func approval(_ name: String, sha: String) -> ScriptApproval {
        ScriptApproval(name: name, sha256: sha, approvedAt: Date(timeIntervalSince1970: 1000))
    }

    @Test("a matching name + hash is approved")
    func approved() {
        let verdict = ScriptApprovalLedger.verdict(
            name: "backup.sh", sha256: "abc123",
            approvals: [approval("backup.sh", sha: "abc123")]
        )
        #expect(verdict == .approved)
    }

    @Test("a script with no approval record is unknown")
    func unknown() {
        let verdict = ScriptApprovalLedger.verdict(
            name: "new.sh", sha256: "abc123",
            approvals: [approval("backup.sh", sha: "abc123")]
        )
        #expect(verdict == .unknown)
    }

    @Test("a hash mismatch is drift — the file changed since the user approved it")
    func drifted() {
        let verdict = ScriptApprovalLedger.verdict(
            name: "backup.sh", sha256: "NEWHASH",
            approvals: [approval("backup.sh", sha: "abc123")]
        )
        #expect(verdict == .drifted(approvedSHA256: "abc123"))
    }

    @Test("UserDefaults store round-trips, replaces same-name, and revokes")
    func storeRoundTrip() throws {
        let suite = "test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsScriptApprovalStore(defaults: defaults)
        #expect(store.approvals().isEmpty)
        store.record(approval("a.sh", sha: "one"))
        store.record(approval("b.sh", sha: "two"))
        store.record(approval("a.sh", sha: "three")) // re-approve replaces
        #expect(store.approvals().count == 2)
        #expect(store.approvals().first { $0.name == "a.sh" }?.sha256 == "three")
        store.revoke(name: "a.sh")
        #expect(store.approvals().map(\.name) == ["b.sh"])
    }
}
