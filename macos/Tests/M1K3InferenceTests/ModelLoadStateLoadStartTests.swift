//
//  ModelLoadStateLoadStartTests.swift
//  M1K3InferenceTests
//
//  Kev, 2026-10-20 (1.1.1/537): "Lil loading … hangs at 0% until jumping to fully loaded." A brain whose weights
//  were already on disk started at `.downloading(0)`, and the local fast path never reports progress, so the bar
//  read "Downloading Lil… 0%" for the whole 44 s Metal load. These pin the start state and the progress fold.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-20, Confidence 0.9. Prior: none (new file).

@testable import M1K3Inference
import Testing

struct ModelLoadStateLoadStartTests {
    @Test("weights on disk start indeterminate, never at 0%")
    func onDiskStartsPreparing() {
        #expect(ModelLoadState.loadStart(weightsOnDisk: true) == .preparing)
    }

    @Test("a real download starts its bar at 0%")
    func downloadStartsAtZero() {
        #expect(ModelLoadState.loadStart(weightsOnDisk: false) == .downloading(fraction: 0))
    }

    @Test("progress folds into a download: a fraction moves the bar, the last byte hands over to preparing")
    func progressFoldsWhileDownloading() {
        #expect(ModelLoadState.progress(0.2).applying(progress: 0.4) == .downloading(fraction: 0.4))
        #expect(ModelLoadState.progress(0.9).applying(progress: 1) == .preparing)
    }

    @Test("bytes arriving while preparing promote it to a bar (weights judged on disk still needed a fetch)")
    func preparingPromotesOnRealProgress() {
        #expect(ModelLoadState.preparing.applying(progress: 0.3) == .downloading(fraction: 0.3))
        #expect(ModelLoadState.preparing.applying(progress: 0) == nil)
        #expect(ModelLoadState.preparing.applying(progress: 1) == nil)
    }

    @Test("progress never rewrites a settled state (a stale hop after ready must not regress the bar)")
    func progressIgnoredOutsideDownload() {
        #expect(ModelLoadState.ready.applying(progress: 0.5) == nil)
        #expect(ModelLoadState.idle.applying(progress: 0.5) == nil)
        #expect(ModelLoadState.failed(message: "x").applying(progress: 0.5) == nil)
    }
}
