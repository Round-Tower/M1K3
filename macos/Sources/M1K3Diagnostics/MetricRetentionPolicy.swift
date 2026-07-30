//
//  MetricRetentionPolicy.swift
//  M1K3Diagnostics
//
//  The pure "which files to prune" decision for the bounded on-disk MetricKit
//  store (Application Support/M1K3/metrickit/, capped at ~50 files per the
//  #86 spec). Deliberately takes already-read file names+dates rather than a
//  directory URL — the actual FileManager scan/delete is app-target glue
//  (MetricKitCollector.swift), so this decision is unit-pinned without any I/O.
//
//  Signed: Kev + claude-fable-5, 2026-07-30, Confidence 0.85 (pure, TDD-pinned).
//  Prior: Unknown.
//

import Foundation

/// One file's identity for the retention decision: a name (to report back for
/// deletion) and a modification date (the pruning order).
public struct MetricStoreFile: Sendable, Equatable {
    public let name: String
    public let date: Date

    public init(name: String, date: Date) {
        self.name = name
        self.date = date
    }
}

public enum MetricRetentionPolicy {
    /// Given the existing files (any order) and a cap on how many to KEEP,
    /// return the names to DELETE — oldest first — so the directory never
    /// holds more than `cap` files. `cap <= 0` means keep none (delete all).
    public static func filesToPrune(_ files: [MetricStoreFile], cap: Int) -> [String] {
        let sorted = files.sorted { $0.date < $1.date }
        guard cap > 0 else { return sorted.map(\.name) }
        guard sorted.count > cap else { return [] }
        let overflow = sorted.count - cap
        return sorted.prefix(overflow).map(\.name)
    }
}
