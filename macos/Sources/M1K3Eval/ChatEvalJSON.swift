//
//  ChatEvalJSON.swift
//  M1K3Eval
//
//  The machine-readable scorecard: one document = provenance + runs, encoded
//  with sorted keys so two runs diff line-by-line. This is what the site's
//  brains.json is generated FROM (ADR 0004: the site publishes evals the app
//  never reads) and what a brain-promotion PR cites. The text transcript stays
//  for eyeballing; this is the primary artifact.
//
//  Provenance is mandatory because the numbers are meaningless without it:
//  a Low Power Mode run reads 15–20% slower and looks exactly like a
//  regression (2026-08-08); the bare arm is structurally blind to the turn
//  shape (BENCHMARKS.md); a single-run cell has no error bars.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-05, Confidence 0.9. Prior: Unknown

import Foundation

/// Where and how a scorecard was measured. Every field is a fact the harness
/// can read off the machine or the caller must state — none is inferred.
public struct EvalProvenance: Sendable, Equatable, Codable {
    /// ISO-8601 UTC.
    public let date: String
    /// e.g. "Apple M1 Max · 64 GB".
    public let hardware: String
    /// e.g. "macOS 26.4".
    public let osVersion: String
    /// The app's git commit, when the build carries it; nil for an unstamped build.
    public let appCommit: String?
    /// The mlx-swift-lm revision the build was compiled against, when known.
    public let mlxSwiftLMRevision: String?
    /// 0 normal / 1 Low Power / 2 High Power, as `pmset -g | rg powermode` reports. The harness can only
    /// read 0-or-1 itself (`ProcessInfo.isLowPowerModeEnabled`); the operator states 2 via
    /// `M1K3_SELFTEST_POWERMODE`. Adaptive Power is invisible here — see `powerSource`.
    public let powerMode: Int?
    /// "ac" / "battery" / "ups", read from IOKit. Added 2026-09-05 after a day of tok/s measured on battery
    /// under Adaptive Power read as "powermode 0": plugged in, plain decode doubled. Optional so scorecards
    /// written before the field decode as `nil` ("unknown"), never as a guess.
    public let powerSource: String?
    /// Whether fixtures ran through the live AgentRAGResponder path.
    public let livePath: Bool
    /// Trials per fixture.
    public let repeats: Int
    /// Anything else that affects the reading (what else was running, thermal state).
    public let notes: String?

    public init(
        date: String, hardware: String, osVersion: String, appCommit: String?, mlxSwiftLMRevision: String?,
        powerMode: Int?, powerSource: String? = nil, livePath: Bool, repeats: Int, notes: String? = nil
    ) {
        self.date = date
        self.hardware = hardware
        self.osVersion = osVersion
        self.appCommit = appCommit
        self.mlxSwiftLMRevision = mlxSwiftLMRevision
        self.powerMode = powerMode
        self.powerSource = powerSource
        self.livePath = livePath
        self.repeats = repeats
        self.notes = notes
    }

    /// The header block the text transcript carries, so the two artifacts agree.
    public var rendered: String {
        var lines = [
            "=== PROVENANCE ===",
            "date \(date)",
            "hardware \(hardware)",
            "os \(osVersion)",
            "app \(appCommit ?? "unstamped")",
            "mlx-swift-lm \(mlxSwiftLMRevision ?? "unknown")",
            "power \(powerSource ?? "unknown") · powermode \(powerMode.map(String.init) ?? "unknown")",
            "live-path \(livePath ? "yes" : "no")",
            "repeats \(repeats)",
        ]
        if let notes, !notes.isEmpty { lines.append("notes \(notes)") }
        return lines.joined(separator: "\n")
    }
}

/// The whole scorecard as one Codable value.
public struct ChatEvalDocument: Sendable, Equatable, Codable {
    public let schemaVersion: Int
    public let provenance: EvalProvenance
    public let runs: [ChatEvalReport.BrainRun]

    public init(provenance: EvalProvenance, runs: [ChatEvalReport.BrainRun]) {
        schemaVersion = 1
        self.provenance = provenance
        self.runs = runs
    }
}

public extension ChatEvalReport {
    /// Pretty-printed, sorted-keys JSON — stable across runs, so `diff` works.
    static func json(_ document: ChatEvalDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }
}
