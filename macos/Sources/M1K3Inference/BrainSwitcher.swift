//
//  BrainSwitcher.swift
//  M1K3Inference
//
//  The pure model behind the chat toolbar's brain hot-swap: one row per tier
//  (selectable / locked / needs-download) and the "currently using X" indicator
//  label. Pure value logic in the seam module (no MLX, no SwiftUI) so it's
//  `swift test`-able; the Menu itself is verify-by-launch.
//
//  The load-bearing invariant lives in `indicatorLabel`: `AppEnvironment.selectBrain`
//  flips the active tier on its FIRST line — BEFORE the weights finish downloading —
//  so the label MUST compose the active tier with the load state, or it would claim
//  "Big M1K3" while Big is still pulling 5 GB. Tested.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-21, Confidence 0.85 (textbook composition;
//  the no-lie-during-download + locked-not-dropped rules are pinned by tests; the
//  toolbar wiring + look are verify-by-launch). Prior: Unknown.
//  Review: Kev + claude-fable-5.1, 2026-09-06 — `rows(…afm:)` lists `BrainTier.offered(afm:)` — never two brains
//  called Mini, never the AFM Mini on a blocked Mac. Default `.available` keeps every existing caller byte-identical.
//  Confidence now 0.85.

import Foundation

/// One entry in the brain switcher menu.
public struct BrainSwitchRow: Identifiable, Equatable, Sendable {
    public let tier: BrainTier
    /// The brain currently selected — gets the checkmark.
    public let isActive: Bool
    /// This Mac lacks the memory to run it — shown disabled, NOT hidden (so the
    /// user sees it exists and why it's unavailable).
    public let isLocked: Bool
    /// Selectable, but its weights aren't on disk yet — tapping should route to the
    /// onboarding download flow, never silently start a multi-GB pull in place.
    public let needsDownload: Bool
    /// The row's menu label: the name, plus a download-size or memory-floor hint.
    public let menuTitle: String

    public var id: String {
        tier.id
    }
}

public enum BrainSwitcher {
    /// One row per OFFERED tier (`BrainTier.offered(afm:)`), in tier order. `isDownloaded` and
    /// `isLocked` are injected predicates (the view passes `env.isBrainDownloaded`
    /// and `{ !$0.isSelectableOnThisMac }`) so this stays pure and deterministic.
    public static func rows(
        active: BrainTier,
        isDownloaded: (BrainTier) -> Bool,
        isLocked: (BrainTier) -> Bool,
        afm: AFMAvailability = .available
    ) -> [BrainSwitchRow] {
        BrainTier.offered(afm: afm, including: active).map { tier in
            let locked = isLocked(tier)
            let needsDownload = !locked && tier.requiresDownload && !isDownloaded(tier)
            return BrainSwitchRow(
                tier: tier,
                isActive: tier == active,
                isLocked: locked,
                needsDownload: needsDownload,
                menuTitle: menuTitle(tier: tier, locked: locked, needsDownload: needsDownload)
            )
        }
    }

    private static func menuTitle(tier: BrainTier, locked: Bool, needsDownload: Bool) -> String {
        if locked, let floor = tier.minimumPhysicalMemoryGB {
            return "\(tier.displayName) · needs \(Int(floor))GB+"
        }
        if needsDownload, let megabytes = tier.approxDownloadMB {
            return "\(tier.displayName) · \(downloadSize(megabytes)) download"
        }
        return tier.displayName
    }

    /// "~2.9 GB" / "~600 MB" from an approx MB figure (1 GB = 1000 MB, matching
    /// how download sizes are quoted to users — not the 1024 binary divisor).
    private static func downloadSize(_ megabytes: Int) -> String {
        guard megabytes >= 1000 else { return "~\(megabytes) MB" }
        return String(format: "~%.1f GB", Double(megabytes) / 1000)
    }

    /// TRUE when re-selecting `tier` would be a pure no-op: it is already the
    /// selected brain, the provider is `.ready`, and the loaded model id matches
    /// the tier's. This is the "no redundant multi-GB reload" invariant —
    /// re-selecting a warm brain must never spin up a fresh provider (cold
    /// persona-KV prefix) for nothing. A non-ready state (failed / downloading /
    /// preparing / idle) falls through so onboarding "Try again" and first-wake
    /// re-attempt; Mini (nil `mlxModelID`) is cheap and never guarded.
    /// Extracted from `AppEnvironment.selectBrain` so the predicate is
    /// unit-testable (109 review nit — the app target has no test bundle).
    public static func reselectIsNoOp(
        tier: BrainTier,
        selected: BrainTier,
        load: ModelLoadState,
        loadedModelID: String?
    ) -> Bool {
        guard tier == selected, load == .ready, let modelID = tier.mlxModelID else { return false }
        return modelID == loadedModelID
    }

    /// The toolbar indicator: the active brain composed WITH the load state, so it
    /// never claims a brain that's still downloading (see the file header).
    public static func indicatorLabel(active: BrainTier, load: ModelLoadState) -> String {
        switch load {
        case let .downloading(fraction):
            return "\(active.displayName) · \(Int((fraction * 100).rounded()))%"
        case .preparing: // on disk, loading weights into memory — not yet ready
            return "\(active.displayName) · loading"
        case .failed:
            return "\(active.displayName) · failed"
        case .idle, .ready: // the only truly settled states → plain name
            return active.displayName
        }
    }
}
