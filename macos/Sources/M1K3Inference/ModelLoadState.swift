//
//  ModelLoadState.swift
//  M1K3Inference
//
//  The progress state for warming a heavy on-device model (MLX Gemma weights are
//  ~1GB and download lazily on first use). Lives in the seam module — not M1K3MLX —
//  so it's pure (no Metal link), `swift test`-able, and the app/UI can observe it
//  without importing MLX. The actual download is verify-by-launch; THIS is the
//  part we can prove green in CI.
//
//  `ModelPreloading` lets a backend warm itself ahead of the first turn, reporting
//  a 0...1 fraction, so the runtime picker can show a real progress bar instead of
//  a silent hang. Only weight-downloading backends conform; cheap ones (Apple
//  Foundation Models) don't need it.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-opus-5.5, 2026-10-12 — TestFlight 505, iPhone: "Lil Waking seems to hang at 0%, with a small amount
//  of progress in the bar." A started download under half a percent read "0%" (rounded) beside a visible sliver; it now
//  reads "<1%". `statusLine` says Downloading while bytes come and Waking once they're in (the load has no number), and
//  `DownloadStallWatch` tells a slow transfer from a dead one (the foreground Hub session dies when the phone locks, and
//  an interrupted file restarts from zero). Confidence 0.85.

import Foundation

/// Where a model load is in its lifecycle. `idle` before anything is asked of it,
/// `downloading` while weights stream in (fraction is clamped to 0...1), `ready`
/// once warm, `failed` with a human message if the load couldn't complete.
public enum ModelLoadState: Sendable, Equatable {
    case idle
    case downloading(fraction: Double)
    /// On disk but still loading, with no honest fraction to show — e.g. WhisperKit
    /// compiling its CoreML models. Renders an indeterminate spinner, never a stuck
    /// bar, and is NOT labelled "downloading" (which read as a phantom re-download).
    case preparing
    case ready
    case failed(message: String)

    /// A `.downloading` state with `fraction` clamped to 0...1 — the only
    /// supported way to build one, so a stray callback value can't escape range.
    public static func progress(_ fraction: Double) -> ModelLoadState {
        .downloading(fraction: min(max(fraction, 0), 1))
    }

    /// The 0...1 fraction for a `ProgressView`, or nil when not downloading.
    public var fraction: Double? {
        if case let .downloading(value) = self { return value }
        return nil
    }

    /// True while a load is in flight (downloading or preparing) — the cue to show
    /// the progress row.
    public var isActive: Bool {
        switch self {
        case .downloading, .preparing: true
        case .idle, .ready, .failed: false
        }
    }

    /// A plain, audio-friendly status line for the UI. `modelName` is the
    /// user-facing label (e.g. "Gemma 3"). Empty while idle so it renders nothing.
    public func label(modelName: String) -> String {
        switch self {
        case .idle:
            return ""
        case let .downloading(fraction):
            return "Downloading \(modelName)… \(percent(fraction))"
        case .preparing:
            return "Preparing \(modelName)…"
        case .ready:
            return "\(modelName) ready"
        case let .failed(message):
            return "Couldn’t load \(modelName): \(message)"
        }
    }

    /// A minimal status for cramped chrome (the toolbar pill): just the percentage
    /// while downloading — the spinner beside it already reads as "loading" — and
    /// nothing while preparing (the spinner alone carries it, there's no honest
    /// number). Keeps the toolbar quiet instead of jamming in "Downloading X… N%".
    public var compactLabel: String {
        switch self {
        case let .downloading(fraction): percent(fraction)
        case .idle, .preparing, .ready, .failed: ""
        }
    }

    /// The one-line status for a progress row (the iPhone chat): "Downloading X… N%" while the bytes come, "Waking X…"
    /// once they are all in or while it loads from disk (no honest number), empty otherwise.
    public func statusLine(modelName: String) -> String {
        switch self {
        case let .downloading(fraction) where fraction < 1:
            "Downloading \(modelName)… \(percent(fraction))"
        case .downloading, .preparing:
            "Waking \(modelName)…"
        case .idle, .ready, .failed:
            ""
        }
    }

    /// Rounded to a whole percent, except that a STARTED download under half a percent reads "<1%": rounding it to
    /// "0%" beside a visible sliver of bar read as a hang (TestFlight 505). Exactly 0 is an honest "0%".
    private func percent(_ fraction: Double) -> String {
        let whole = Int((fraction * 100).rounded())
        return whole == 0 && fraction > 0 ? "<1%" : "\(whole)%"
    }
}

/// Tells a slow download from a dead one. The Hub bridge repeats its last fraction as a heartbeat, so only a CHANGED
/// value resets the clock (a drop counts: an interrupted file restarts from zero and is moving again);
/// `isStalled` is true once nothing has moved for `threshold` while bytes are still owed.
public struct DownloadStallWatch: Sendable, Equatable {
    /// Long enough that a slow link's pauses don't cry wolf, short enough that a dead transfer is named.
    public static let threshold: TimeInterval = 20

    private var lastFraction: Double?
    private var lastAdvance: Date?

    public init() {}

    /// Record a progress report at `now`.
    public mutating func observe(_ fraction: Double, at now: Date) {
        guard fraction != lastFraction else { return }
        lastFraction = fraction
        lastAdvance = now
    }

    public func isStalled(at now: Date) -> Bool {
        guard let lastFraction, let lastAdvance, lastFraction < 1 else { return false }
        return now.timeIntervalSince(lastAdvance) >= Self.threshold
    }

    public mutating func reset() {
        self = DownloadStallWatch()
    }
}

/// A backend that can warm its model ahead of the first request, reporting
/// download/load progress as a 0...1 fraction. Conformed to by weight-downloading
/// providers (MLX) so the app can preload on selection and surface a progress bar.
public protocol ModelPreloading: Sendable {
    /// Ensure the model is loaded, invoking `progress` with a 0...1 fraction as
    /// weights download. Returns once the model is ready; throws on failure.
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws
}
