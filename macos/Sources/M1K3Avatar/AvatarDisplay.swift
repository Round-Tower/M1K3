//
//  AvatarDisplay.swift
//  M1K3Avatar
//
//  Where the avatar shows in the Mac chat: the window's backdrop, or not at all. The 200 pt
//  panel is retired (Kev, 2026-10-11, TestFlight: "background or off — no panel"; standing
//  ruling 2026-09-25, one full-screen avatar, boxed avatars are fallbacks only). Lives in the
//  package so the legacy-value mapping is testable and every `@AppStorage` reader agrees.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.85. Prior: none (new file;
//  the enum moved here from M1K3App/AppEnvironment+Avatar.swift).
//

import Foundation

public enum AvatarDisplay: String, CaseIterable, Identifiable, Sendable {
    /// Full-window backdrop behind the glass bubbles; recedes while reading/typing.
    case background
    /// No avatar — just the transcript.
    case off

    public var id: String {
        rawValue
    }

    public static let defaultValue: AvatarDisplay = .background

    /// The `UserDefaults` / `@AppStorage` key (unchanged since the three-way picker).
    public static let storageKey = "chat.avatarDisplay"

    /// Reads a stored raw value. A legacy `"panel"` (retired) and anything unknown or
    /// missing land on the default, so every reader resolves the same way.
    public init(persisted raw: String?) {
        switch raw {
        case "off": self = .off
        case "background": self = .background
        default: self = Self.defaultValue
        }
    }
}
