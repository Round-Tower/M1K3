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
//    · Mini is listed unless the hardware is ineligible (`.blocked(userFixable:
//      false)`) — switched-off Apple Intelligence is the user's to fix, so the
//      row stays with its hint; `.notReady` is a transient sync.
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

    public static func resolve(afm: AFMAvailability, physicalMemoryGB gigabytes: Double) -> MobileBrainMenu {
        var options: [MobileBrainOption] = []
        if afm != .blocked(userFixable: false) {
            options.append(.tier(.mini))
        }
        if BrainTier.lil.isSelectable(forPhysicalMemoryGB: gigabytes, platform: .mobile) {
            options.append(.tier(.lil))
        }
        options.append(.brainAtHome)

        let ladder = MobileBrainOption.tier(
            BrainTier.recommended(forPhysicalMemoryGB: gigabytes, platform: .mobile)
        )
        let recommended: MobileBrainOption = if options.contains(ladder) {
            ladder
        } else if options.contains(.tier(.lil)) {
            .tier(.lil)
        } else if options.contains(.tier(.mini)) {
            .tier(.mini)
        } else {
            .brainAtHome
        }

        let hasLocal = options.contains { if case .tier = $0 { true } else { false } }
        let device = HostPlatform.thisDevice
        let sentenceDevice = device.prefix(1).uppercased() + device.dropFirst()
        return MobileBrainMenu(
            options: options,
            recommended: recommended,
            localFallback: options.contains(.tier(.lil)) ? .lil : nil,
            note: hasLocal ? nil : "\(sentenceDevice) can’t run a brain of its own — use your Mac’s over Wi‑Fi."
        )
    }
}
