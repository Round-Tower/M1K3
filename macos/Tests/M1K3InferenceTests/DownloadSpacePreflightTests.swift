//
//  DownloadSpacePreflightTests.swift
//  M1K3InferenceTests
//
//  The iPhone started a brain download with no look at free space: a full phone failed every attempt,
//  late, in words that blamed the network (the first App Store review, 2026-11-01: "Everytime I try to
//  download Mini it fails"). The check runs before any byte moves and says how much is missing.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-03, Confidence 0.85. Prior: Unknown.
//

@testable import M1K3Inference
import Testing

struct DownloadSpacePreflightTests {
    private let mb: Int64 = 1_000_000

    @Test("room for the download and the headroom: no problem")
    func enoughRoom() {
        #expect(DownloadSpacePreflight.shortfallMB(downloadMB: 630, availableBytes: 2000 * mb) == nil)
        #expect(DownloadSpacePreflight.shortfallMB(downloadMB: 630, availableBytes: 930 * mb) == nil)
    }

    @Test("short: the shortfall counts the headroom, rounded up")
    func short() {
        #expect(DownloadSpacePreflight.shortfallMB(downloadMB: 630, availableBytes: 500 * mb) == 430)
        #expect(DownloadSpacePreflight.shortfallMB(downloadMB: 630, availableBytes: 929 * mb + 1) == 1)
    }

    @Test("an unreadable volume (0 bytes) never blocks: the download's own error still speaks")
    func unknownNeverBlocks() {
        #expect(DownloadSpacePreflight.shortfallMB(downloadMB: 630, availableBytes: 0) == nil)
    }

    @Test("the message names the brain, the size and what's missing, in the bar's units")
    func message() {
        let error = DownloadSpacePreflight.InsufficientSpace(brain: "Mini", downloadMB: 630, shortfallMB: 430)
        #expect(error.errorDescription == "Not enough space for Mini. It needs about 630 MB, and this device is "
            + "430 MB short. Free some space, then pick Mini again.")
        let big = DownloadSpacePreflight.InsufficientSpace(brain: "Lil", downloadMB: 3060, shortfallMB: 1200)
        #expect(big.errorDescription?.contains("about 3.1 GB, and this device is 1.2 GB short") == true)
    }
}
