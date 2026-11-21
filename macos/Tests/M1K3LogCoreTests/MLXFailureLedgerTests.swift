//
//  MLXFailureLedgerTests.swift
//  M1K3LogCoreTests
//
//  The last few MLX errors a device hit, kept on disk so a report can say what failed (2026-11-21: 15
//  crash logs from iPhones, every one an MLX error with no handler, and not one carried MLX's message).
//  Pinned here: newest first, bounded, sanitised, durable across instances, and safe on a bad file.
//
//  Signed: claude-opus-5-5, 2026-11-21, Confidence 0.85. Prior: none (new file).
//

import Foundation
@testable import M1K3LogCore
import Testing

struct MLXFailureLedgerTests {
    private func freshLedger() -> MLXFailureLedger {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-ledger-\(UUID().uuidString)")
            .appendingPathComponent("mlx-failures.json")
        return MLXFailureLedger(fileURL: url)
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("a recorded error reads back as one dated line")
    func recordsOne() {
        let ledger = freshLedger()
        ledger.record("[metal::malloc] Unable to allocate 268435456 bytes.", at: t0)
        #expect(ledger.lines(now: t0) == ["2027-01-15T08:00:00Z [metal::malloc] Unable to allocate 268435456 bytes."])
    }

    @Test("newest first, and only the last few are kept")
    func newestFirstBounded() {
        let ledger = freshLedger()
        for i in 0 ..< (MLXFailureLedger.maxEntries + 3) {
            ledger.record("error \(i)", at: t0.addingTimeInterval(Double(i)))
        }
        let lines = ledger.lines(now: t0.addingTimeInterval(60))
        #expect(lines.count == MLXFailureLedger.maxEntries)
        #expect(lines.first?.hasSuffix("error \(MLXFailureLedger.maxEntries + 2)") == true)
        #expect(lines.last?.hasSuffix("error 3") == true)
    }

    @Test("a message is one line, trimmed and capped")
    func sanitised() throws {
        let ledger = freshLedger()
        let long = String(repeating: "x", count: 1000)
        ledger.record("  [METAL] Command buffer\nexecution failed:\t\(long)  ", at: t0)
        let line = try #require(ledger.lines(now: t0).first)
        #expect(!line.contains("\n"))
        #expect(line.contains("[METAL] Command buffer execution failed:"))
        let message = MLXFailureLedger.sanitize("  [METAL] Command buffer\nexecution failed:\t\(long)  ")
        #expect(message.count == MLXFailureLedger.maxMessageLength)
        #expect(message.hasSuffix("…"))
        #expect(MLXFailureLedger.sanitize("   ") == "unknown MLX error")
        // mlx-c's source-file suffix goes, MLX's words stay (seen on Kev's 17 Pro, 2026-11-21).
        #expect(MLXFailureLedger.sanitize(
            "[broadcast_shapes] Shapes (2,5) and (3,5) cannot be broadcast. at /tmp/x/mlx-c/mlx/c/ops.cpp:42"
        ) == "[broadcast_shapes] Shapes (2,5) and (3,5) cannot be broadcast.")
    }

    @Test("lines older than the window are left out of a report")
    func windowed() {
        let ledger = freshLedger()
        ledger.record("old", at: t0)
        ledger.record("new", at: t0.addingTimeInterval(MLXFailureLedger.reportWindow + 10))
        let lines = ledger.lines(now: t0.addingTimeInterval(MLXFailureLedger.reportWindow + 20))
        #expect(lines.count == 1)
        #expect(lines.first?.hasSuffix("new") == true)
        let skewed = freshLedger()
        skewed.record("from a clock ahead", at: t0.addingTimeInterval(3600))
        #expect(skewed.lines(now: t0).isEmpty, "an entry dated after now is a skewed clock, not a recent error")
    }

    @Test("what one instance wrote, a fresh one reads: the next launch after a crash sees it")
    func durable() {
        let ledger = freshLedger()
        ledger.record("before the crash", at: t0)
        let nextLaunch = MLXFailureLedger(fileURL: ledger.fileURL)
        #expect(nextLaunch.lines(now: t0).first?.hasSuffix("before the crash") == true)
    }

    @Test("a missing or unreadable file reads as nothing, and the next record still lands")
    func tolerant() throws {
        let ledger = freshLedger()
        #expect(ledger.lines(now: t0).isEmpty)
        try FileManager.default.createDirectory(
            at: ledger.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: ledger.fileURL)
        #expect(ledger.lines(now: t0).isEmpty)
        ledger.record("after", at: t0)
        #expect(ledger.lines(now: t0).count == 1)
    }

    @Test("records from many threads at once all survive within the bound")
    func concurrent() async {
        let ledger = freshLedger()
        let start = t0
        await withTaskGroup(of: Void.self) { group in
            for i in 0 ..< 20 {
                group.addTask { ledger.record("e\(i)", at: start.addingTimeInterval(Double(i))) }
            }
        }
        #expect(ledger.lines(now: t0.addingTimeInterval(60)).count == MLXFailureLedger.maxEntries)
    }
}
