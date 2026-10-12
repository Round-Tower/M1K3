//
//  ModelLoadStateTests.swift
//  M1K3InferenceTests
//
//  Contract tests for the model-load progress state machine — the pure piece
//  behind "MLX Gemma is downloading, don't look frozen". No MLX, no Metal: this
//  is exactly the bit that CAN run under `swift test` (the real download is
//  verify-by-launch only), so it's where the logic lives and gets pinned.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.9, Prior: Unknown
//  Review: Kev + claude-opus-5.5, 2026-10-12 — TestFlight 505, iPhone "hangs at 0%": a started download reads "<1%",
//  `statusLine` (downloading vs waking) and `DownloadStallWatch`. Confidence 0.9.

import Foundation
@testable import M1K3Inference
import Testing

struct ModelLoadStateTests {
    @Test("progress clamps a fraction into 0...1")
    func clampsFraction() {
        #expect(ModelLoadState.progress(-0.5) == .downloading(fraction: 0))
        #expect(ModelLoadState.progress(0.42) == .downloading(fraction: 0.42))
        #expect(ModelLoadState.progress(1.7) == .downloading(fraction: 1))
    }

    @Test("fraction is exposed only while downloading")
    func fractionAccessor() {
        #expect(ModelLoadState.progress(0.3).fraction == 0.3)
        #expect(ModelLoadState.idle.fraction == nil)
        #expect(ModelLoadState.ready.fraction == nil)
        #expect(ModelLoadState.failed(message: "x").fraction == nil)
    }

    @Test("isActive is true only mid-download")
    func isActive() {
        #expect(ModelLoadState.progress(0).isActive)
        #expect(ModelLoadState.progress(1).isActive)
        #expect(!ModelLoadState.idle.isActive)
        #expect(!ModelLoadState.ready.isActive)
        #expect(!ModelLoadState.failed(message: "x").isActive)
    }

    @Test("preparing is active, indeterminate, and labelled as prep — not a download")
    func preparing() {
        // For a model that's on disk but still loading (e.g. WhisperKit's opaque
        // CoreML compile), there's no honest fraction — show a spinner, and DON'T
        // say "Downloading" (the lie that read as a re-download).
        #expect(ModelLoadState.preparing.isActive) // the row still shows
        #expect(ModelLoadState.preparing.fraction == nil) // → indeterminate bar
        #expect(ModelLoadState.preparing.label(modelName: "WhisperKit") == "Preparing WhisperKit…")
    }

    @Test("failure carries its message")
    func failureMessage() {
        let state = ModelLoadState.failed(message: "no network")
        #expect(state == .failed(message: "no network"))
        #expect(state.fraction == nil)
    }

    @Test("label is human, dyslexia-friendly, and names the model")
    func labels() {
        #expect(ModelLoadState.idle.label(modelName: "Gemma 3") == "")
        #expect(ModelLoadState.progress(0.42).label(modelName: "Gemma 3") == "Downloading Gemma 3… 42%")
        #expect(ModelLoadState.progress(0).label(modelName: "Gemma 3") == "Downloading Gemma 3… 0%")
        #expect(ModelLoadState.ready.label(modelName: "Gemma 3") == "Gemma 3 ready")
        #expect(ModelLoadState.failed(message: "offline").label(modelName: "Gemma 3")
            == "Couldn’t load Gemma 3: offline")
    }

    @Test("label rounds the percentage to the nearest whole number")
    func labelRounds() {
        #expect(ModelLoadState.progress(0.006).label(modelName: "M") == "Downloading M… 1%")
        #expect(ModelLoadState.progress(0.994).label(modelName: "M") == "Downloading M… 99%")
        #expect(ModelLoadState.progress(0.999).label(modelName: "M") == "Downloading M… 100%")
    }

    @Test("compactLabel is just the number while downloading, empty otherwise")
    func compactLabel() {
        // The toolbar pill keeps only the percentage; the spinner beside it says "loading".
        #expect(ModelLoadState.progress(0.42).compactLabel == "42%")
        #expect(ModelLoadState.progress(1).compactLabel == "100%")
        // No frozen number where there's no honest fraction — the spinner alone carries it.
        #expect(ModelLoadState.preparing.compactLabel == "")
        #expect(ModelLoadState.idle.compactLabel == "")
        #expect(ModelLoadState.ready.compactLabel == "")
        #expect(ModelLoadState.failed(message: "x").compactLabel == "")
    }

    /// TestFlight 505 (2026-10-12), iPhone: "Lil Waking seems to hang at 0%, with a small amount of progress in the bar."
    @Test("a started download never reads 0%: under half a percent is <1%; an unstarted one is an honest 0%")
    func startedDownloadNeverReadsZero() {
        #expect(ModelLoadState.progress(0.004).label(modelName: "Lil") == "Downloading Lil… <1%")
        #expect(ModelLoadState.progress(0.0001).compactLabel == "<1%")
        #expect(ModelLoadState.progress(0).label(modelName: "Lil") == "Downloading Lil… 0%")
        #expect(ModelLoadState.progress(0.006).label(modelName: "Lil") == "Downloading Lil… 1%")
    }

    @Test("statusLine: downloading while the bytes come, waking once they are in (the load has no honest number)")
    func statusLine() {
        #expect(ModelLoadState.progress(0.42).statusLine(modelName: "Lil") == "Downloading Lil… 42%")
        #expect(ModelLoadState.progress(0.002).statusLine(modelName: "Lil") == "Downloading Lil… <1%")
        #expect(ModelLoadState.progress(1).statusLine(modelName: "Lil") == "Waking Lil…")
        #expect(ModelLoadState.preparing.statusLine(modelName: "Lil") == "Waking Lil…")
        #expect(ModelLoadState.idle.statusLine(modelName: "Lil") == "")
        #expect(ModelLoadState.ready.statusLine(modelName: "Lil") == "")
    }
}

struct DownloadStallWatchTests {
    private let t0 = Date(timeIntervalSince1970: 1000)

    @Test("a changed value resets the clock, a drop included (a restart is moving); the heartbeat's repeat does not")
    func changesOnly() {
        var watch = DownloadStallWatch()
        watch.observe(0.01, at: t0)
        #expect(!watch.isStalled(at: t0.addingTimeInterval(19)))
        watch.observe(0.01, at: t0.addingTimeInterval(15))
        #expect(watch.isStalled(at: t0.addingTimeInterval(20)))
        watch.observe(0.02, at: t0.addingTimeInterval(21))
        #expect(!watch.isStalled(at: t0.addingTimeInterval(40)))
        #expect(watch.isStalled(at: t0.addingTimeInterval(41)))
        watch.observe(0.001, at: t0.addingTimeInterval(42))
        #expect(!watch.isStalled(at: t0.addingTimeInterval(50)))
    }

    @Test("never stalled before the first report, once the bytes are all in, or after a reset")
    func quietEdges() {
        var watch = DownloadStallWatch()
        #expect(!watch.isStalled(at: t0.addingTimeInterval(600)))
        watch.observe(1, at: t0)
        #expect(!watch.isStalled(at: t0.addingTimeInterval(600)))
        watch.observe(0.5, at: t0)
        watch.reset()
        #expect(!watch.isStalled(at: t0.addingTimeInterval(600)))
    }
}

/// Source pins on the iPhone shell (no pure seam: SwiftUI + UIApplication). The download itself is verify-on-device.
struct IOSBrainDownloadRowScanTests {
    private static func code(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("the chat row reads the shared status line (never a truncated Int percent) and names a stall")
    func rowCopy() throws {
        let chat = try Self.code("M1K3iOSApp/ChatScreen.swift")
        #expect(!chat.contains("Int(fraction * 100)"), "the row truncates again: under 1% reads 0%")
        #expect(chat.contains("core.brainLoad.statusLine(modelName:"))
        #expect(chat.contains("core.brainStall.isStalled(at:"))
    }

    @Test("the screen stays on while a brain downloads, from the root (Settings pushed over chat keeps it)")
    func keepAwake() throws {
        let root = try Self.code("M1K3iOSApp/RootView.swift")
        #expect(root.contains(".onChange(of: core.isDownloadingBrain, initial: true)"))
        #expect(root.contains("UIApplication.shared.isIdleTimerDisabled = downloading"))
        let core = try Self.code("M1K3iOSApp/AppCore.swift")
        #expect(core.contains("brainStall.observe(fraction, at: Date())"))
        #expect(core.contains("brainStall.reset()"))
    }
}
