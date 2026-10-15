//
//  ContinuedDownload.swift
//  M1K3Inference
//
//  What a user-started brain download asks of iOS 26's continued-processing task (BGContinuedProcessingTask):
//  iOS keeps the download running when the person leaves the app and shows its progress itself, on the Lock
//  Screen and in the Dynamic Island (Kev, 2026-10-12: Apple's progress UI, not a branded one). Network and CPU
//  only: an iPhone answers no to background GPU (`BGTaskScheduler.supportedResources`, read on Kev's 17 Pro), and
//  MLX traps rather than throws on background Metal work, so the weights load only in the foreground.
//
//  The pure half: the identifier under the Info.plist wildcard, the words the system shows, progress units, and
//  the two foreground/background rules. The task, the system UI and the background run are verify-on-device.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-12, Confidence 0.8 (pure parts pinned; the background run is device-only).
//  Prior: none (new file; the Live Activities plan's slice 1).
//

import Foundation

public struct ContinuedDownload: Sendable, Equatable {
    /// The Info.plist `BGTaskSchedulerPermittedIdentifiers` entry. A request's identifier is this with the `*`
    /// replaced (the SDK's `<MainBundle>.<SemanticContext>.*` shape).
    public static let permittedIdentifiers = "app.m1k3.download.*"
    /// Progress in permille. A task that looks stalled may be expired by the scheduler, and 1 % of Lil is 30 MB.
    public static let totalUnits: Int64 = 1000

    public let identifier: String
    /// The system Live Activity's title and subtitle.
    public let title: String
    public let subtitle: String

    public init(tier: BrainTier) {
        identifier = String(Self.permittedIdentifiers.dropLast()) + tier.rawValue
        title = "Downloading \(tier.displayName)"
        subtitle = "\(Self.sizeLine(megabytes: tier.approxDownloadMB)), kept on this device"
    }

    public static func completedUnits(fraction: Double) -> Int64 {
        Int64((min(max(fraction, 0), 1) * Double(totalUnits)).rounded(.down))
    }

    /// After the bytes are in: load now only while the app is active. MLX may not touch the GPU in the background
    /// (it traps), so a download that finishes there loads when the person comes back.
    public static func loadsNow(appIsActive: Bool) -> Bool {
        appIsActive
    }

    /// The system expires a task when the person cancels it from the Live Activity, or under pressure. In the
    /// background that stops the download (the app is about to be suspended anyway); in the foreground the download
    /// carries on as an ordinary one and only the task is let go.
    public static func expiryStopsDownload(appIsActive: Bool) -> Bool {
        !appIsActive
    }

    private static func sizeLine(megabytes: Int?) -> String {
        guard let megabytes else { return "A one-time download" }
        if megabytes < 1000 { return "About \(megabytes) MB" }
        // Fixed format, not the locale's: the app's copy is English-only, so "3,1 GB" would read as a typo.
        return "About \(String(format: "%.1f", Double(megabytes) / 1000)) GB"
    }
}
