//
//  MiniContextWindowTests.swift
//  M1K3InferenceTests
//
//  Mini's window is the DEVICE's, not the author's Mac's: an M1 Max reports
//  4,096 (AFM 3 Core), the WWDC26 sample prints 8,192 — so the budget reads
//  `SystemLanguageModel.contextSize` at launch instead of pinning 4,096.
//  Only the pure resolution is tested here: the store is written by the app
//  shells at launch, never by a test (Swift Testing runs suites in parallel,
//  and a test that moved the process-wide window would move every other
//  test's Mini budget with it).
//
//  Signed: Kev + claude-opus-5-5, 2026-09-27, Confidence 0.9. Prior: Unknown
//  Review: Kev + claude-opus-5-5, 2026-09-27 (2), Confidence 0.9 — #422 review: the no-record rule is
//  enforced by a source scan of Tests/ (non-vacuous: >100 files), not just this comment.
//

import Foundation
import M1K3Inference
import Testing

struct MiniContextWindowTests {
    @Test("an unknown window falls back to the 4,096 floor every device has shipped with")
    func unknownFallsBackToFloor() {
        #expect(MiniContextWindow.resolve(reported: nil) == 4096)
        #expect(MiniContextWindow.resolve(reported: 0) == 4096)
        #expect(MiniContextWindow.resolve(reported: -1) == 4096)
    }

    @Test("a bigger device window is used as reported — no author-Mac limit")
    func largerWindowIsUsed() {
        #expect(MiniContextWindow.resolve(reported: 8192) == 8192)
        #expect(MiniContextWindow.resolve(reported: 16384) == 16384)
    }

    @Test("a SMALLER reported window is believed, never rounded up — AFM throws on overflow")
    func smallerWindowIsBelieved() {
        #expect(MiniContextWindow.resolve(reported: 2048) == 2048)
    }

    @Test("an absurd report is capped at the sanity ceiling")
    func absurdReportIsCapped() {
        #expect(MiniContextWindow.resolve(reported: 1_000_000) == MiniContextWindow.ceilingTokens)
        #expect(MiniContextWindow.ceilingTokens == 32768)
    }

    @Test("with nothing recorded, the process window is the floor — and so is BrainTier.mini's")
    func unrecordedStoreIsTheFloor() {
        // Holds in the test process because no test records a window (header).
        #expect(MiniContextWindow.current == MiniContextWindow.floorTokens)
        #expect(BrainTier.mini.approximateContextTokens == MiniContextWindow.current)
    }

    /// #422 review: the "never record from a test" rule was a comment. Every
    /// floor-assuming test in the package (BrainTier, grounding, history, the
    /// raw cap) leans on it, and suites share one process — so it's enforced
    /// here by scanning the test sources.
    @Test("no test anywhere records a window — the store is process-wide")
    func noTestRecordsTheWindow() throws {
        var root = URL(filePath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: root.appending(path: "Package.swift").path) {
            root = root.deletingLastPathComponent()
            try #require(root.path != "/", "no Package.swift above \(#filePath)")
        }
        let tests = root.appending(path: "Tests")
        let files = FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil)
        var offenders: [String] = []
        var scanned = 0
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift", url.lastPathComponent != "MiniContextWindowTests.swift" else { continue }
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.contains("MiniContextWindow.record(") || text.contains("recordDeviceContextWindow(") {
                offenders.append(url.lastPathComponent)
            }
        }
        #expect(scanned > 100, "scanned only \(scanned) test files — the guard would pass vacuously")
        #expect(offenders.isEmpty, "these tests move every suite's Mini window: \(offenders)")
    }
}
