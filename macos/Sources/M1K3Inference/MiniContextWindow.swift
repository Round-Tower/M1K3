//
//  MiniContextWindow.swift
//  M1K3Inference
//
//  Mini's context window is the DEVICE's. It was a literal 4,096 — the figure
//  AFM reported on the M1 Max every Mini budget was tuned on (AFM 3 Core,
//  2026-09-13) — while the WWDC26 Foundation Models sample prints 8,192 for
//  the rebuilt on-device model. A constant would hold every newer device to
//  the author's Mac. The app shells read `SystemLanguageModel.contextSize` at
//  launch (`AppleFoundationModelsProvider.deviceContextSize()`) and `record`
//  it here; every budget that asks `BrainTier.mini.approximateContextTokens`
//  then sizes to the real window.
//
//  Direction of failure: an unknown window is the 4,096 floor (safe on every
//  device AFM has shipped on); a SMALLER report is believed, never rounded up
//  — AFM throws on overflow, it does not truncate (afm-mini-4096-window).
//
//  Signed: Kev + claude-opus-5-5, 2026-09-27, Confidence 0.8 (resolution
//  pinned in MiniContextWindowTests; the >4,096 path is unit-tested only —
//  this Mac reports 4,096, so a newer device's launch log is the live proof).
//  Prior: Unknown
//

import Foundation
import Synchronization

public enum MiniContextWindow {
    /// What every budget assumes until the device says otherwise.
    public static let floorTokens = 4096
    /// A sanity cap on a report, not a target: Private Cloud Compute's window
    /// (32,768) is the largest any Apple language model has advertised.
    public static let ceilingTokens = 32768

    private static let recorded = Mutex<Int?>(nil)

    /// The window to budget against for a reported `contextSize`.
    public static func resolve(reported: Int?) -> Int {
        guard let reported, reported > 0 else { return floorTokens }
        return min(reported, ceilingTokens)
    }

    /// Called once per launch by the app shell with the device's report (nil
    /// when AFM is unavailable or the OS predates the API). Never from tests —
    /// the store is process-wide and suites run in parallel.
    public static func record(reported: Int?) {
        let window = resolve(reported: reported)
        recorded.withLock { $0 = window }
    }

    /// The window in force: the recorded one, else the floor.
    public static var current: Int {
        recorded.withLock { $0 } ?? floorTokens
    }
}
