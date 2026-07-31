//
//  MetricRetentionPolicyTests.swift
//  M1K3DiagnosticsTests
//
//  Pure decision layer for the bounded MetricKit on-disk store: given file
//  names+dates+a cap, which files to delete so the directory never grows past
//  a "few MB / ~50 files" bound. The actual FileManager I/O lives in the app
//  target glue (MetricKitCollector); this is the unit-pinned "which" decision.
//

import Foundation
@testable import M1K3Diagnostics
import Testing

struct MetricRetentionPolicyTests {
    private func file(_ name: String, daysAgo: Double) -> MetricStoreFile {
        MetricStoreFile(name: name, date: Date(timeIntervalSince1970: 1_000_000 - daysAgo * 86400))
    }

    @Test("fewer files than the cap prunes nothing")
    func underCap() {
        let files = [file("a", daysAgo: 1), file("b", daysAgo: 2)]
        #expect(MetricRetentionPolicy.filesToPrune(files, cap: 50).isEmpty)
    }

    @Test("exactly at the cap prunes nothing")
    func exactlyAtCap() {
        let files = [file("a", daysAgo: 1), file("b", daysAgo: 2)]
        #expect(MetricRetentionPolicy.filesToPrune(files, cap: 2).isEmpty)
    }

    @Test("over the cap prunes the OLDEST files first")
    func overCapPrunesOldest() {
        let files = [
            file("newest", daysAgo: 0),
            file("middle", daysAgo: 1),
            file("oldest", daysAgo: 2),
        ]
        let pruned = MetricRetentionPolicy.filesToPrune(files, cap: 2)
        #expect(pruned == ["oldest"])
    }

    @Test("well over the cap prunes every overflow file, oldest-first order")
    func farOverCap() {
        let files = [
            file("d1", daysAgo: 0),
            file("d2", daysAgo: 1),
            file("d3", daysAgo: 2),
            file("d4", daysAgo: 3),
            file("d5", daysAgo: 4),
        ]
        let pruned = MetricRetentionPolicy.filesToPrune(files, cap: 2)
        #expect(pruned == ["d5", "d4", "d3"])
    }

    @Test("an empty file list prunes nothing regardless of cap")
    func emptyList() {
        #expect(MetricRetentionPolicy.filesToPrune([], cap: 10).isEmpty)
        #expect(MetricRetentionPolicy.filesToPrune([], cap: 0).isEmpty)
    }

    @Test("a cap of zero prunes every file")
    func zeroCap() {
        let files = [file("a", daysAgo: 0), file("b", daysAgo: 1)]
        let pruned = MetricRetentionPolicy.filesToPrune(files, cap: 0)
        #expect(Set(pruned) == Set(["a", "b"]))
    }

    @Test("a negative cap is treated the same as zero — prune everything")
    func negativeCap() {
        let files = [file("a", daysAgo: 0)]
        #expect(MetricRetentionPolicy.filesToPrune(files, cap: -1) == ["a"])
    }
}
