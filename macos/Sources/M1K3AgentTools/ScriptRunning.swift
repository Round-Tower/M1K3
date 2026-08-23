//
//  ScriptRunning.swift
//  M1K3AgentTools
//
//  The OS seam for the "hands" (docs/CONTEXT_TOOLS_PLAN.md architecture rule):
//  pure value types + a protocol, so ExecuteScriptTool is fully testable
//  against fakes. The live implementation (UserScriptRunner) wraps
//  NSUserUnixTask over ~/Library/Application Scripts/app.m1k3 — the macOS
//  sandbox's sanctioned script folder: the app can only run what the user has
//  installed there, so the folder itself is the outer consent boundary.
//
//  Signed: Kev + claude-fable-5, 2026-08-23, Confidence 0.9, Prior: Unknown

import Foundation

/// One script present in the scripts folder, with the content hash the
/// approval ledger pins against.
public struct InstalledScript: Sendable, Equatable {
    public let name: String
    /// Lowercase hex SHA-256 of the file's exact bytes.
    public let sha256: String

    public init(name: String, sha256: String) {
        self.name = name
        self.sha256 = sha256
    }
}

/// What one run produced. `succeeded` is honest to NSUserUnixTask's contract:
/// the API reports completion-or-error, never a raw exit code, so failure
/// carries a human `failureReason` instead of a fabricated status number.
public struct ScriptRunOutcome: Sendable, Equatable {
    public let succeeded: Bool
    public let failureReason: String?
    /// Combined stdout+stderr, capped by the runner (tail kept).
    public let output: String
    public let duration: TimeInterval
    /// True when the wait was abandoned at the timeout. NSUserUnixTask cannot
    /// be terminated once launched — the script may still be running; callers
    /// must say so rather than pretend it was killed.
    public let timedOut: Bool

    public init(
        succeeded: Bool, failureReason: String?, output: String,
        duration: TimeInterval, timedOut: Bool
    ) {
        self.succeeded = succeeded
        self.failureReason = failureReason
        self.output = output
        self.duration = duration
        self.timedOut = timedOut
    }
}

/// Unrecoverable launch problems (missing file, not executable, bad name).
/// Distinct from a script that ran and failed — that's a `ScriptRunOutcome`.
public enum ScriptRunFailure: Error, Equatable {
    case launchFailed(String)
}

/// Runs installed user scripts. Seam so the tool tests against a fake and the
/// NSUserUnixTask adapter stays thin.
public protocol ScriptRunning: Sendable {
    /// The scripts currently present in the folder, hashed.
    func installedScripts() async -> [InstalledScript]
    /// Run one by file name (never a path), bounded by `timeout` seconds.
    /// `expectedSHA256` is re-checked against the file's CURRENT bytes
    /// immediately before launch (TOCTOU close: the folder lives outside the
    /// sandbox container, so a co-resident process could swap the file between
    /// the tool's approval snapshot and this call — a drift here refuses).
    func run(
        named name: String, arguments: [String], timeout: TimeInterval, expectedSHA256: String
    ) async throws -> ScriptRunOutcome
}

/// A runner that can never execute — the persona-prefix warm needs only tool
/// DEFINITIONS (names, descriptions, schemas), never a live run, so wiring a
/// real UserScriptRunner into the warm hook was a footgun: a future change that
/// accidentally called `execute()` would run a real script at app-launch with
/// no user interaction (Finding 9). The warm uses this instead.
public struct NullScriptRunning: ScriptRunning {
    public init() {}
    public func installedScripts() async -> [InstalledScript] {
        []
    }

    public func run(
        named _: String, arguments _: [String], timeout _: TimeInterval, expectedSHA256 _: String
    ) async throws -> ScriptRunOutcome {
        throw ScriptRunFailure.launchFailed("warm-only runner never executes")
    }
}

/// An approval store that grants nothing — pairs with NullScriptRunning for the
/// warm hook, so even a mis-wired warm can't authorise a run.
public struct EmptyScriptApprovalStore: ScriptApprovalStoring {
    public init() {}
    public func approvals() -> [ScriptApproval] {
        []
    }

    public func record(_: ScriptApproval) {}
    public func revoke(name _: String) {}
}
