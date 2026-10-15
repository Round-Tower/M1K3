//
//  ContinuedDownloadTests.swift
//  M1K3InferenceTests
//
//  The pure half of a brain download that carries on when the person leaves the app (iOS 26's
//  continued-processing task; Kev, 2026-10-12: "Lil Waking seems to hang at 0%" and "Apple's" progress UI).
//  The task itself, the system's Live Activity and the background run are verify-on-device.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-12, Confidence 0.85. Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-15 (pre-push review fold) — pins: the disk is checked before iOS hears the
//  download succeeded. Confidence 0.85.
//

import Foundation
@testable import M1K3Inference
import Testing

struct ContinuedDownloadTests {
    @Test("the identifier sits under the Info.plist wildcard, one per brain")
    func identifier() {
        #expect(ContinuedDownload.permittedIdentifiers == "app.m1k3.download.*")
        #expect(ContinuedDownload(tier: .lil).identifier == "app.m1k3.download.lil")
        #expect(ContinuedDownload(tier: .pocket).identifier == "app.m1k3.download.pocket")
        let prefix = String(ContinuedDownload.permittedIdentifiers.dropLast())
        for tier in BrainTier.allCases where tier.requiresDownload {
            #expect(ContinuedDownload(tier: tier).identifier.hasPrefix(prefix))
        }
    }

    @Test("the system Live Activity's words: what is downloading, how big, and where it stays")
    func words() {
        let lil = ContinuedDownload(tier: .lil)
        #expect(lil.title == "Downloading Lil")
        #expect(lil.subtitle == "About 3.1 GB, kept on this device")
        #expect(ContinuedDownload(tier: .pocket).subtitle == "About 630 MB, kept on this device")
    }

    @Test("progress in permille: fine enough that a slow link never reads as stalled, clamped, never past done")
    func units() {
        #expect(ContinuedDownload.totalUnits == 1000)
        #expect(ContinuedDownload.completedUnits(fraction: 0) == 0)
        #expect(ContinuedDownload.completedUnits(fraction: 0.0049) == 4)
        #expect(ContinuedDownload.completedUnits(fraction: 0.4206) == 420)
        #expect(ContinuedDownload.completedUnits(fraction: 1) == 1000)
        #expect(ContinuedDownload.completedUnits(fraction: 1.7) == 1000)
        #expect(ContinuedDownload.completedUnits(fraction: -0.2) == 0)
    }

    @Test("MLX may load only in the foreground: a download that finishes in the background loads on return")
    func loadOnlyWhenActive() {
        #expect(ContinuedDownload.loadsNow(appIsActive: true))
        #expect(!ContinuedDownload.loadsNow(appIsActive: false))
    }

    @Test("an expiry in the background stops the download; in the foreground it only lets go of the task")
    func expiry() {
        #expect(ContinuedDownload.expiryStopsDownload(appIsActive: false))
        #expect(!ContinuedDownload.expiryStopsDownload(appIsActive: true))
    }
}

/// Source pins on the iPhone wiring (BackgroundTasks + UIKit, no pure seam). How it runs is verify-on-device.
struct ContinuedDownloadWiringScanTests {
    private static func code(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test("the iOS target (only) permits the wildcard; the visionOS target has no continued tasks")
    func infoPlist() throws {
        let yml = try Self.code("project.yml")
        let ios = yml.components(separatedBy: "\n  M1K3iOS:").dropFirst().first?
            .components(separatedBy: "\n  M1K3visionOS:").first ?? ""
        #expect(ios.contains("BGTaskSchedulerPermittedIdentifiers:"))
        #expect(ios.contains("- \"app.m1k3.download.*\""))
        let vision = yml.components(separatedBy: "\n  M1K3visionOS:").dropFirst().first ?? ""
        #expect(!vision.contains("BGTaskSchedulerPermittedIdentifiers"))
    }

    @Test("the task registers once per identifier (a second registration kills the app), fails fast, and expires by the rule")
    func task() throws {
        let task = try Self.code("M1K3iOSApp/ContinuedDownloadTask.swift")
        #expect(task.contains("#if os(iOS)"))
        #expect(task.contains("private static var registered: Set<String>"))
        #expect(task.contains("guard !registered.contains(plan.identifier)") || task.contains("if !registered.contains(plan.identifier)"))
        #expect(task.contains("request.strategy = .fail"))
        #expect(task.contains("ContinuedDownload.expiryStopsDownload(appIsActive:"))
        #expect(task.contains("ContinuedDownload.completedUnits(fraction:"))
    }

    @Test("the warm downloads to disk first and loads only in the foreground")
    func warm() throws {
        let core = try Self.code("M1K3iOSApp/AppCore.swift")
        let warm = core.components(separatedBy: "private func warmSelectedBrain()").dropFirst().first ?? ""
        let fetchAt = try #require(warm.range(of: "downloadWeights(modelID:"))
        let prepareAt = try #require(warm.range(of: "mlx.prepare"))
        #expect(fetchAt.lowerBound < prepareAt.lowerBound)
        #expect(warm.contains("ContinuedDownload.loadsNow(appIsActive:"))
        #expect(core.contains("BrainWeightsFetcher().fetch(modelID:"))
        #expect(core.contains("ContinuedDownloadTask.begin("))
        // A stopped download is not retried by a foreground bounce (warmForForeground only re-warms .idle).
        #expect(warm.contains("Task.isCancelled || error is CancellationError"))
    }

    @Test("a fetch that returns is checked against the disk before iOS hears it succeeded")
    func verifiedBeforeSuccess() throws {
        // The downloader returns instead of throwing when offline; the rule is LocalModelInventoryTests'
        // requireCompleteBelievesTheDisk. Without this the Lock Screen said done and the warm logged "downloaded in
        // the background" with no weights on disk.
        let core = try Self.code("M1K3iOSApp/AppCore.swift")
        let download = try #require(core.components(separatedBy: "private func downloadWeights(").dropFirst().first)
        let fetchAt = try #require(download.range(of: "BrainWeightsFetcher().fetch(modelID:"))
        let checkAt = try #require(download.range(of: "try LocalModelInventory().requireComplete(modelID: modelID)"))
        let successAt = try #require(download.range(of: "continued?.finish(success: true)"))
        #expect(fetchAt.lowerBound < checkAt.lowerBound && checkAt.lowerBound < successAt.lowerBound)
    }

    @Test("'iOS carries it' is true only while the task is attached: a foreground expiry hands it back")
    func carriedOnlyWhileAttached() throws {
        // Set from the submission alone, the flag outlived an expiry in the foreground (the person cancels from
        // the Dynamic Island): the download carried on as an ordinary one with the screen allowed to sleep and the
        // row still saying "keeps downloading if you leave", so auto-lock suspended it and the file restarted.
        let task = try Self.code("M1K3iOSApp/ContinuedDownloadTask.swift")
        let attach = try #require(task.components(separatedBy: "private func attach(").dropFirst().first)
            .components(separatedBy: "private func expired()").first ?? ""
        #expect(attach.contains("onCarry(true)"))
        let expired = try #require(task.components(separatedBy: "private func expired()").dropFirst().first)
        let releasedAt = try #require(expired.range(of: "onCarry(false)"))
        let stopAt = try #require(expired.range(of: "ContinuedDownload.expiryStopsDownload(appIsActive:"))
        #expect(releasedAt.lowerBound < stopAt.lowerBound)
        let core = try Self.code("M1K3iOSApp/AppCore.swift")
        #expect(!core.contains("brainDownloadContinues = continued != nil"))
        #expect(core.contains("self?.brainDownloadContinues = carried"))
    }

    @Test("while iOS carries the download the screen may sleep, and the row says the person can leave")
    func copyAndKeepAwake() throws {
        let root = try Self.code("M1K3iOSApp/RootView.swift")
        #expect(root.contains(".onChange(of: core.isDownloadingBrain && !core.brainDownloadContinues, initial: true)"))
        let chat = try Self.code("M1K3iOSApp/ChatScreen.swift")
        #expect(chat.contains("keeps downloading if you leave M1K3."))
    }
}
