//
//  MetricPayloadDigest.swift
//  M1K3Diagnostics
//
//  A best-effort, bounded summary of ONE MetricKit payload's raw JSON
//  (`MXDiagnosticPayload`/`MXMetricPayload .jsonRepresentation()`), for the
//  "Report an issue" opt-in inclusion and the collector's own log breadcrumb.
//  Deliberately NOT a crash-log parser: MetricKit's JSON shape is Apple's own
//  undocumented internal encoding (no published schema, no versioning
//  guarantee), so this looks for well-known KEY NAMES anywhere in the tree —
//  the top-level diagnostic-kind arrays, `timeStampBegin`/`timeStampEnd`, an
//  `appVersion`/`appBuildVersion` string, and a `binaryName` for the "top
//  frame" — rather than assuming a fixed nesting. That makes it robust to
//  Apple reshuffling the schema, at the cost of only ever reading the FIRST
//  match it finds; it never walks a full call-stack tree.
//
//  Platform-coverage note lives with `MetricKitCollector.swift` (verified
//  against the macOS 26 SDK headers) — this type only ever sees JSON `Data`
//  and doesn't import MetricKit at all, so it's Foundation-only and portable.
//
//  Signed: Kev + claude-fable-5, 2026-07-30, Confidence 0.8 (unit-pinned
//  against hand-built fixtures shaped like Apple's documented/sampled JSON —
//  the exact real-device shape is verify-by-crash, not provable from here).
//  Prior: Unknown.
//

import Foundation

/// The diagnostic/metric KIND a payload represents, in priority order when a
/// payload happens to carry more than one non-empty array (real payloads
/// shouldn't, but the reader doesn't assume that).
public enum MetricPayloadKind: String, Sendable, Equatable, CaseIterable {
    case crash
    case hang
    case cpuException = "cpu-exception"
    case diskWriteException = "disk-write-exception"
    /// iOS-only in practice (`MXDiagnosticPayload.appLaunchDiagnostics` is
    /// `API_UNAVAILABLE(macos)`) — recognised generically anyway so a
    /// digest never mislabels one as `.unknown`.
    case appLaunch = "app-launch"
    /// No diagnostic array present but the payload carries a time range —
    /// the daily `MXMetricPayload` shape (launch/memory/battery aggregates).
    case metrics
    case unknown
}

/// One payload's summary — bounded, human-readable, and safe to log or hand
/// to the "Report an issue" flow: never the raw payload text.
public struct MetricPayloadSummary: Sendable, Equatable {
    public let kind: MetricPayloadKind
    public let date: Date?
    public let appVersion: String?
    public let topFrame: String?

    public init(kind: MetricPayloadKind, date: Date?, appVersion: String?, topFrame: String?) {
        self.kind = kind
        self.date = date
        self.appVersion = appVersion
        self.topFrame = topFrame
    }

    // `nonisolated(unsafe)`: `ISO8601DateFormatter`/`DateFormatter` aren't
    // Sendable (same non-Sendable-Foundation-formatter situation as
    // `LogPreview.whitespaceRun` in M1K3LogCore), but this instance is only
    // ever configured once here and used read-only (`.string(from:)`) after —
    // sound to share across threads.
    private nonisolated(unsafe) static let lineFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// One bounded "`kind · date · vVersion · topFrame`" line, omitting any
    /// field that couldn't be read. Never the payload's raw text.
    public var line: String {
        var parts = [kind.rawValue]
        if let date { parts.append(Self.lineFormatter.string(from: date)) }
        if let appVersion { parts.append("v\(appVersion)") }
        if let topFrame { parts.append(topFrame) }
        return parts.joined(separator: " · ")
    }
}

public enum MetricPayloadDigest {
    /// Non-empty top-level array keys that identify a diagnostic KIND, most
    /// actionable first (a crash outranks a hang if a payload somehow carried
    /// both — MetricKit's own JSON encoder is not something this reads a
    /// spec for, so this is deliberately defensive).
    private static let kindKeys: [(key: String, kind: MetricPayloadKind)] = [
        ("crashDiagnostics", .crash),
        ("hangDiagnostics", .hang),
        ("cpuExceptionDiagnostics", .cpuException),
        ("diskWriteExceptionDiagnostics", .diskWriteException),
        ("appLaunchDiagnostics", .appLaunch),
    ]

    /// Apple's documented ISO8601 date shape, tried first. `nonisolated(unsafe)`
    /// — see `lineFormatter` above; read-only after construction.
    private nonisolated(unsafe) static let isoDate = ISO8601DateFormatter()

    /// The empirically-observed `NSDate.description` shape MetricKit's own
    /// JSON encoder has been seen emitting for `timeStampBegin`/`End`
    /// ("2026-07-29 00:00:00 +0000") — undocumented, tried as a fallback only.
    private nonisolated(unsafe) static let nsDateDescriptionShape: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// Summarize one payload's raw JSON. Malformed/non-object data degrades
    /// to `.unknown` with every field nil — never throws.
    public static func summarize(_ data: Data) -> MetricPayloadSummary {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else {
            return MetricPayloadSummary(kind: .unknown, date: nil, appVersion: nil, topFrame: nil)
        }

        return MetricPayloadSummary(
            kind: kind(of: root),
            date: date(in: root),
            // Each key gets its OWN full-tree search, in preference order —
            // a shallow appBuildVersion in one array element must never win
            // over an appVersion that appears deeper/later in the tree.
            appVersion: firstString(forKey: "appVersion", in: root, maxDepth: 6)
                ?? firstString(forKey: "appBuildVersion", in: root, maxDepth: 6),
            topFrame: firstString(forKey: "binaryName", in: root, maxDepth: 10)
        )
    }

    private static func kind(of root: [String: Any]) -> MetricPayloadKind {
        for candidate in kindKeys where (root[candidate.key] as? [Any]).map({ !$0.isEmpty }) == true {
            return candidate.kind
        }
        if root["timeStampBegin"] != nil || root["timeStampEnd"] != nil {
            return .metrics
        }
        return .unknown
    }

    private static func date(in root: [String: Any]) -> Date? {
        guard let raw = (root["timeStampBegin"] as? String) ?? (root["timeStampEnd"] as? String) else {
            return nil
        }
        return isoDate.date(from: raw) ?? nsDateDescriptionShape.date(from: raw)
    }

    /// Depth-bounded search for the first string value at `key`, anywhere in
    /// the tree (dictionaries and arrays), depth-first. Bounded so a
    /// pathological/adversarial payload can't spin unboundedly. One key per
    /// call (not several) so a caller preferring key A over key B can search
    /// the WHOLE tree for A before ever falling back to B — a shallow B
    /// match must never shadow a deeper/later A match.
    private static func firstString(forKey key: String, in value: Any, maxDepth: Int) -> String? {
        guard maxDepth > 0 else { return nil }
        if let dict = value as? [String: Any] {
            if let match = dict[key] as? String { return match }
            for (_, nested) in dict {
                if let found = firstString(forKey: key, in: nested, maxDepth: maxDepth - 1) { return found }
            }
        } else if let array = value as? [Any] {
            for nested in array {
                if let found = firstString(forKey: key, in: nested, maxDepth: maxDepth - 1) { return found }
            }
        }
        return nil
    }
}
