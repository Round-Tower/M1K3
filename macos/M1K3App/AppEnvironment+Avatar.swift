//
//  AppEnvironment+Avatar.swift
//  M1K3App
//
//  Avatar-presentation settings. One control governs how M1K3's avatar
//  (companion / constellation / pixel face) appears in the chat: the window
//  backdrop or off. The choice itself (`AvatarDisplay`) lives in M1K3Avatar.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-17, Confidence 0.9, Prior: Unknown
//  Review: Kev + claude-opus-5.5, 2026-10-11 — the 200 pt panel is retired (Kev, TestFlight:
//  "background or off — no panel"), so the enum moved to the package with a legacy "panel" →
//  background mapping; this file keeps only the SwiftUI labels/glyphs. Confidence 0.85
//

import Foundation
import M1K3Avatar

extension AvatarDisplay {
    var label: String {
        switch self {
        case .background: String(localized: "Background")
        case .off: String(localized: "Off")
        }
    }

    /// Toolbar glyph for the CURRENT mode.
    var systemImage: String {
        switch self {
        case .background: "rectangle.fill.on.rectangle.fill"
        case .off: "bird"
        }
    }

    /// The mode a toolbar toggle press switches to.
    var toggled: AvatarDisplay {
        self == .background ? .off : .background
    }
}

extension AppEnvironment {
    /// The `@AppStorage` key for `AvatarDisplay`. Read the raw value through
    /// `AvatarDisplay(persisted:)` so a stored legacy "panel" resolves to the backdrop everywhere.
    nonisolated static let avatarDisplayKey = AvatarDisplay.storageKey
}
