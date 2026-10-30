//
//  CompanionAssets.swift
//  M1K3Avatar
//
//  Locates the bundled per-clip companion USDZs. The assets live as package
//  resources (Package.swift `resources: [.copy("Companions")]`) so the app loads
//  them through this package's `Bundle.module` — no app-target resource wiring,
//  no xcodegen. Layout: Companions/<id>/<clip>.usdz.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-11, Confidence 0.8, Prior: Unknown
//  Review: Kev + claude-opus-5.5, 2026-10-30 — `isComplete`, the rule for what may enter the process-wide clip
//  cache (a cut-off harvest stuck a creature on its idle loop). Confidence 0.8.

import Foundation

public enum CompanionAssets {
    /// URL of one companion clip's USDZ, or nil if it isn't bundled.
    public static func clipURL(companion: String, clip: String) -> URL? {
        Bundle.module.url(
            forResource: clip,
            withExtension: "usdz",
            subdirectory: "Companions/\(companion)"
        )
    }

    /// True when the spec's resting clip is bundled — i.e. the companion can
    /// actually be loaded. The picker offers only installed companions.
    public static func isInstalled(_ spec: CompanionSpec) -> Bool {
        clipURL(companion: spec.id, clip: spec.idleClip) != nil
    }

    /// Every bundled clip URL for a spec, in `clips` order, skipping any missing.
    public static func clipURLs(for spec: CompanionSpec) -> [(clip: String, url: URL)] {
        spec.clips.compactMap { clip in
            clipURL(companion: spec.id, clip: clip).map { (clip, $0) }
        }
    }

    /// True when `harvested` holds every clip bundled for the companion. A cancelled harvest comes
    /// back partial, often the idle clip alone; only a complete one may be kept for the process,
    /// or the creature can never act again.
    public static func isComplete(_ harvested: some Sequence<String>, for spec: CompanionSpec) -> Bool {
        Set(clipURLs(for: spec).map(\.clip)).isSubset(of: harvested)
    }
}
