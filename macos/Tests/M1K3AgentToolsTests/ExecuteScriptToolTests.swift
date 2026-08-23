//
//  ExecuteScriptToolTests.swift
//  M1K3AgentToolsTests
//
//  The first "hands" tool: contract + every refusal lane (traversal, not
//  installed, never approved, hash drift), the success/failure/timeout
//  observation shapes, and the argument/timeout parsing. The live NSUserUnixTask
//  adapter has its own tests; here the runner is a fake.
//
//  Signed: Kev + claude-fable-5, 2026-08-23, Confidence 0.9, Prior: Unknown

import Foundation
@testable import M1K3AgentTools
import Testing

private struct RecordedRun: Equatable {
    let name: String
    let arguments: [String]
    let timeout: TimeInterval
    let sha: String
}

private final class FakeRunner: ScriptRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _scripts: [InstalledScript]
    private var _outcome: ScriptRunOutcome
    private var _thrown: Error?
    private var _runs: [RecordedRun] = []

    init(
        scripts: [InstalledScript] = [],
        outcome: ScriptRunOutcome = ScriptRunOutcome(
            succeeded: true, failureReason: nil, output: "ok", duration: 0.1, timedOut: false
        ),
        thrown: Error? = nil
    ) {
        _scripts = scripts
        _outcome = outcome
        _thrown = thrown
    }

    var runs: [RecordedRun] {
        lock.withLock { _runs }
    }

    func installedScripts() async -> [InstalledScript] {
        lock.withLock { _scripts }
    }

    func run(
        named name: String, arguments: [String], timeout: TimeInterval, expectedSHA256: String
    ) async throws -> ScriptRunOutcome {
        try lock.withLock {
            _runs.append(RecordedRun(name: name, arguments: arguments, timeout: timeout, sha: expectedSHA256))
            if let error = _thrown { throw error }
            return _outcome
        }
    }
}

private final class InMemoryApprovalStore: ScriptApprovalStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ScriptApproval] = []

    init(_ approvals: [ScriptApproval] = []) {
        items = approvals
    }

    func approvals() -> [ScriptApproval] {
        lock.withLock { items }
    }

    func record(_ approval: ScriptApproval) {
        lock.withLock {
            items.removeAll { $0.name == approval.name }
            items.append(approval)
        }
    }

    func revoke(name: String) {
        lock.withLock { items.removeAll { $0.name == name } }
    }
}

struct ExecuteScriptToolTests {
    private static let now = Date(timeIntervalSince1970: 1000)

    private func makeTool(
        scripts: [InstalledScript] = [InstalledScript(name: "backup.sh", sha256: "abc")],
        approvals: [ScriptApproval] = [ScriptApproval(name: "backup.sh", sha256: "abc", approvedAt: now)],
        outcome: ScriptRunOutcome = ScriptRunOutcome(
            succeeded: true, failureReason: nil, output: "42 files", duration: 0.2, timedOut: false
        )
    ) -> (ExecuteScriptTool, FakeRunner) {
        let runner = FakeRunner(scripts: scripts, outcome: outcome)
        let tool = ExecuteScriptTool(runner: runner, approvals: InMemoryApprovalStore(approvals))
        return (tool, runner)
    }

    @Test("declares the execute_script contract the model sees")
    func contract() {
        let (tool, _) = makeTool()
        #expect(tool.name == "execute_script")
        #expect(tool.parameters.first?.name == "script")
        #expect(tool.parameters.first?.isRequired == true)
        #expect(tool.parameters.contains { $0.name == "arguments" && !$0.isRequired })
        #expect(tool.parameters.contains { $0.name == "timeout_seconds" && !$0.isRequired })
        #expect(tool.requiresExclusiveCompute == false)
        #expect(tool.exclusionClass == .localSensitive)
    }

    @Test("an approved script runs and the observation carries its output")
    func runsApproved() async throws {
        let (tool, runner) = makeTool()
        let result = try await tool.execute(input: ["script": "backup.sh"])
        #expect(!result.output.hasPrefix("Error:"))
        #expect(result.output.contains("42 files"))
        #expect(runner.runs.count == 1)
        #expect(runner.runs.first?.timeout == 60) // default
    }

    @Test("arguments split on whitespace; timeout parses and is clamped to 300s")
    func argumentAndTimeoutParsing() async throws {
        let (tool, runner) = makeTool()
        _ = try await tool.execute(input: [
            "script": "backup.sh", "arguments": "  --fast  photos ", "timeout_seconds": "9999",
        ])
        #expect(runner.runs.first?.arguments == ["--fast", "photos"])
        #expect(runner.runs.first?.timeout == 300)
    }

    @Test("a non-numeric timeout is a recoverable error, nothing runs")
    func badTimeout() async throws {
        let (tool, runner) = makeTool()
        let result = try await tool.execute(input: ["script": "backup.sh", "timeout_seconds": "soon"])
        #expect(result.output.hasPrefix("Error:"))
        #expect(runner.runs.isEmpty)
    }

    @Test("a non-finite timeout (inf/nan) is refused, nothing runs — no Task.sleep crash")
    func nonFiniteTimeout() async throws {
        let (tool, runner) = makeTool()
        for raw in ["inf", "-inf", "nan", "1e400"] {
            let result = try await tool.execute(input: ["script": "backup.sh", "timeout_seconds": raw])
            #expect(result.output.hasPrefix("Error:"), "expected refusal for \(raw)")
        }
        #expect(runner.runs.isEmpty)
    }

    @Test("a tab in the script name is refused (plain-file-name intent)")
    func tabInNameRefused() async throws {
        let (tool, runner) = makeTool()
        let result = try await tool.execute(input: ["script": "back\tup.sh"])
        #expect(result.output.hasPrefix("Error:"))
        #expect(runner.runs.isEmpty)
    }

    @Test("an empty script name is a recoverable error")
    func emptyName() async throws {
        let (tool, runner) = makeTool()
        let result = try await tool.execute(input: [:])
        #expect(result.output.hasPrefix("Error:"))
        #expect(runner.runs.isEmpty)
    }

    @Test("path traversal shapes never reach the runner")
    func refusesTraversal() async throws {
        let (tool, runner) = makeTool()
        for name in ["../evil.sh", "/bin/sh", "dir/child.sh", ".hidden.sh", "a/../b.sh"] {
            let result = try await tool.execute(input: ["script": name])
            #expect(result.output.hasPrefix("Error:"), "expected refusal for \(name)")
        }
        #expect(runner.runs.isEmpty)
    }

    @Test("a script that is not installed is refused, listing what is")
    func refusesUninstalled() async throws {
        let (tool, runner) = makeTool()
        let result = try await tool.execute(input: ["script": "missing.sh"])
        #expect(result.output.hasPrefix("Error:"))
        #expect(result.output.contains("backup.sh")) // steer toward what exists
        #expect(runner.runs.isEmpty)
    }

    @Test("an installed but never-approved script is refused")
    func refusesUnapproved() async throws {
        let (tool, runner) = makeTool(approvals: [])
        let result = try await tool.execute(input: ["script": "backup.sh"])
        #expect(result.output.hasPrefix("Error:"))
        #expect(result.output.contains("approve"))
        #expect(runner.runs.isEmpty)
    }

    @Test("a script whose bytes drifted since approval is refused — the tell is named")
    func refusesDrift() async throws {
        let (tool, runner) = makeTool(
            approvals: [ScriptApproval(name: "backup.sh", sha256: "OLD", approvedAt: Self.now)]
        )
        let result = try await tool.execute(input: ["script": "backup.sh"])
        #expect(result.output.hasPrefix("Error:"))
        #expect(result.output.contains("changed"))
        #expect(runner.runs.isEmpty)
    }

    @Test("a failed run is an Error observation carrying the reason and output")
    func failedRun() async throws {
        let (tool, _) = makeTool(outcome: ScriptRunOutcome(
            succeeded: false, failureReason: "exit status 3", output: "boom", duration: 0.1, timedOut: false
        ))
        let result = try await tool.execute(input: ["script": "backup.sh"])
        #expect(result.output.hasPrefix("Error:"))
        #expect(result.output.contains("exit status 3"))
        #expect(result.output.contains("boom"))
    }

    @Test("a timeout is an Error observation that says the script may still be running")
    func timedOutRun() async throws {
        let (tool, _) = makeTool(outcome: ScriptRunOutcome(
            succeeded: false, failureReason: nil, output: "partial", duration: 60, timedOut: true
        ))
        let result = try await tool.execute(input: ["script": "backup.sh"])
        #expect(result.output.hasPrefix("Error:"))
        #expect(result.output.contains("still be running"))
        #expect(result.output.contains("partial"))
    }

    @Test("the approved hash is threaded to the runner for its exec-boundary re-check")
    func passesApprovedHash() async throws {
        let (tool, runner) = makeTool()
        _ = try await tool.execute(input: ["script": "backup.sh"])
        #expect(runner.runs.first?.sha == "abc")
    }

    @Test("successful output is fenced as untrusted data")
    func outputFenced() async throws {
        let (tool, _) = makeTool()
        let result = try await tool.execute(input: ["script": "backup.sh"])
        #expect(result.output.contains("untrusted data"))
    }

    @Test("long output is trimmed to a tail, and says so")
    func outputCapped() async throws {
        let long = String(repeating: "x", count: 10000) + "TAIL-MARKER"
        let (tool, _) = makeTool(outcome: ScriptRunOutcome(
            succeeded: true, failureReason: nil, output: long, duration: 0.1, timedOut: false
        ))
        let result = try await tool.execute(input: ["script": "backup.sh"])
        #expect(result.output.count < 5000)
        #expect(result.output.contains("TAIL-MARKER"))
        #expect(result.output.contains("trimmed"))
    }
}
