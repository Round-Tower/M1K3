//
//  MobileBrainMenu.swift
//  M1K3Inference
//
//  Which brains the iOS/iPadOS/visionOS shell may LIST on this device, and which
//  to recommend. Before this, onboarding and Settings hard-coded [.mini, .lil]:
//  an iPad with no Apple Intelligence was shown Mini anyway (it could never
//  answer), a 3 GB iPad saw Lil dimmed behind a memory badge, and the paired
//  Mac's brain — the only thing that device can actually run — was not on the
//  menu at all (Kev's iPad, QA pass 2026-09-05). Pure so the whole table is
//  `swift test`-able; the shell supplies live AFM availability + RAM.
//
//  Rules:
//    · One Mini per device (`BrainTier.offered(afm:)`): Apple's when it can serve
//      (`.available`, and `.notReady` — a transient sync), pocket (LFM2.5-1.2B)
//      whenever it is `.blocked` — either reason; the Settings hint still points
//      a user-fixable block at the switch. Pocket has its own mobile floor.
//    · Lil is listed only when it clears the mobile memory floor (BrainTier).
//    · Big is never listed on mobile (the floor is infinite there).
//    · Brain at Home is ALWAYS listed, last — pairing is a real choice on every
//      device, and on a device with no local brain it is the way in.
//    · The recommendation is the mobile ladder's tier when it is listed, else
//      the best local tier that is, else Brain at Home.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-05, Confidence 0.85 (pinned by
//  MobileBrainMenuTests; the device-shape assumptions come from Kev's iPad
//  8th gen + iPhone 17 Pro). Prior: none (new file).
//  Review: Kev + claude-fable-5.1, 2026-09-05 — `hasLocalBrain` (backed by `note`): the shell auto-activates a paired
//  Mac when it is false. Confidence now 0.9.
//  Review: Kev + claude-fable-5.1, 2026-09-06 — options come from `BrainTier.offered(afm:)` filtered by the mobile
//  floor (Big never); a blocked device gets pocket as its Mini, Lil recommended over pocket where memory allows;
//  `localFallback` falls back to pocket. The 3 GB A12 class is still Home-only (pocket's 3.5 GB floor). Confidence
//  now 0.9.
//

import Foundation

/// One row of the mobile brain menu.
public enum MobileBrainOption: Equatable, Sendable, Hashable, Identifiable {
    case tier(BrainTier)
    case brainAtHome

    public var id: String {
        switch self {
        case let .tier(tier): tier.rawValue
        case .brainAtHome: "home"
        }
    }
}

public struct MobileBrainMenu: Equatable, Sendable {
    /// The rows to show, in order. Never empty — Brain at Home is always last.
    public let options: [MobileBrainOption]
    /// The row to badge "Recommended".
    public let recommended: MobileBrainOption
    /// The local tier a "Mini can't run here" hint should point at, or nil when
    /// pairing with a Mac is the only alternative.
    public let localFallback: BrainTier?
    /// One plain-words line when this device can run NO local brain, else nil.
    public let note: String?

    /// False when Home is the only row: the shell then activates a paired Mac
    /// on its own (after pairing, and at launch) instead of leaving the device on
    /// a Mini that can never answer (Kev's iPad, round 3).
    public var hasLocalBrain: Bool {
        note == nil // one truth table: `resolve` sets the note exactly when no tier is listed
    }

    public static func resolve(afm: AFMAvailability, physicalMemoryGB gigabytes: Double) -> MobileBrainMenu {
        // One Mini per device (BrainTier.offered): AFM's when it can serve,
        // pocket (LFM2.5-1.2B) when Apple Intelligence is blocked. Big never
        // fits a mobile budget; Lil needs its 8 GB floor.
        var options: [MobileBrainOption] = BrainTier.offered(afm: afm)
            .filter { $0 != .big && $0.isSelectable(forPhysicalMemoryGB: gigabytes, platform: .mobile) }
            .map(MobileBrainOption.tier)
        options.append(.brainAtHome)

        let ladder = MobileBrainOption.tier(
            BrainTier.recommended(forPhysicalMemoryGB: gigabytes, platform: .mobile, afm: afm)
        )
        // A roomy device without Apple Intelligence gets Lil over pocket —
        // capability first where the memory allows it.
        let recommended: MobileBrainOption = if options.contains(.tier(.lil)), afm.isBlocked {
            .tier(.lil)
        } else if options.contains(ladder) {
            ladder
        } else if options.contains(.tier(.lil)) {
            .tier(.lil)
        } else {
            .brainAtHome
        }

        let hasLocal = options.contains { if case .tier = $0 { true } else { false } }
        let device = HostPlatform.thisDevice
        let sentenceDevice = device.prefix(1).uppercased() + device.dropFirst()
        return MobileBrainMenu(
            options: options,
            recommended: recommended,
            localFallback: options.contains(.tier(.lil)) ? .lil
                : options.contains(.tier(.pocket)) ? .pocket : nil,
            note: hasLocal ? nil : "\(sentenceDevice) can’t run a brain of its own — use your Mac’s over Wi‑Fi."
        )
    }
}
