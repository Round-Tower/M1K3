//
//  RetiredWeightsPolicy.swift
//  M1K3MLX
//
//  Which downloaded brain folders are RETIRED — on disk, but claimed by nothing:
//  not a pinned repo, not a shipped tier, not the model loaded right now. A
//  re-pin leaves the previous brain behind (Lil's 2026-09-05 move to DWQ-2510
//  stranded 2.2 GB) and nothing offered to clean it up; this is the pure half
//  of that offer. It only ever LISTS — removal is a user tap in Settings, never
//  automatic, because a spike or A/B checkpoint on disk may be deliberate.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-05, Confidence 0.85 (pure set
//  difference + sort, pinned by RetiredWeightsTests; the Settings row and the
//  delete are verify-by-launch). Prior: none. Issue #222.

import Foundation

/// One downloaded repo folder and what it weighs on disk.
public struct InstalledWeights: Equatable, Hashable, Sendable, Identifiable {
    public let repoID: String
    public let bytes: Int64
    public var id: String {
        repoID
    }

    public init(repoID: String, bytes: Int64) {
        self.repoID = repoID
        self.bytes = bytes
    }
}

public enum RetiredWeightsPolicy {
    /// Folders in `installed` that no id in `keep` claims, largest first.
    /// `keep` is the union the caller assembles: `PinnedWeights.all` keys, every
    /// shipped tier's `mlxModelID`, and whatever model is loaded right now.
    public static func retired(installed: [InstalledWeights], keep: Set<String>) -> [InstalledWeights] {
        installed
            .filter { !keep.contains($0.repoID) }
            .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.repoID < $1.repoID }
    }

    /// What removing every retired folder would free.
    public static func totalBytes(_ retired: [InstalledWeights]) -> Int64 {
        retired.reduce(0) { $0 + $1.bytes }
    }
}
