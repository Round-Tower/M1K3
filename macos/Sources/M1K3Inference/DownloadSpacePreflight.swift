//
//  DownloadSpacePreflight.swift
//  M1K3Inference
//
//  Is there room for a brain download, before any byte moves? The iPhone never asked: a full phone
//  failed every attempt, late, in words that blamed the network (the first App Store review,
//  2026-11-01: "Everytime I try to download Mini it fails"). Pure; the shell reads the volume's
//  `volumeAvailableCapacityForImportantUsage` (which counts space iOS will purge for us).
//
//  Signed: Kev + claude-opus-5.5, 2026-11-03, Confidence 0.8 (the 300 MB headroom is a judgement:
//  the tokenizer, config and the temp file's rename need a little more than the weights). Prior: Unknown.
//

import Foundation

public enum DownloadSpacePreflight {
    /// Room needed beyond the weights themselves.
    public static let headroomMB = 300

    /// Megabytes missing, rounded up, or nil when there is room. A volume that reads 0 bytes is unknown,
    /// not full: it never blocks, and the download's own error speaks if space really runs out.
    public static func shortfallMB(downloadMB: Int, availableBytes: Int64) -> Int? {
        guard availableBytes > 0 else { return nil }
        let needed = Int64(downloadMB + headroomMB) * 1_000_000
        guard availableBytes < needed else { return nil }
        let missing = needed - availableBytes
        return Int((missing + 999_999) / 1_000_000)
    }

    public struct InsufficientSpace: Error, LocalizedError, Equatable {
        public let brain: String
        public let downloadMB: Int
        public let shortfallMB: Int

        public init(brain: String, downloadMB: Int, shortfallMB: Int) {
            self.brain = brain
            self.downloadMB = downloadMB
            self.shortfallMB = shortfallMB
        }

        public var errorDescription: String? {
            let size = BrainTier.downloadSizeLabel(megabytes: downloadMB)
            let short = BrainTier.downloadSizeLabel(megabytes: shortfallMB)
            return "Not enough space for \(brain). It needs about \(size), and this device is \(short) short. "
                + "Free some space, then pick \(brain) again."
        }
    }
}
