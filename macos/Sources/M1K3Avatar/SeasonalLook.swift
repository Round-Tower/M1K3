//
//  SeasonalLook.swift
//  M1K3Avatar
//
//  The date-gated seasonal wardrobe. Halloween: Oct 24 00:00 through Nov 1 23:59:59 in
//  the USER's calendar (their time zone, not UTC), M1K3 wears a pumpkin / ember / violet
//  phosphor and greets you in costume. Pure and dependency-free so the window, the
//  opt-out and the launch-argument override are all unit-tested off-device; the shader
//  and the greeting are verify-by-launch.
//
//  Launch argument: `M1K3 -seasonalLook halloween` forces the look on, `-seasonalLook none`
//  forces it off (screenshots, store art, verification). Read from the ARGUMENT domain only,
//  like `GenerationActivity.isEnabled`: on macOS 27 `defaults write` never reaches the
//  sandboxed app, and a persisted key must never force a look in a shipped build.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.85 (pure date maths pinned by
//  tests; the on-screen look is verify-by-launch). Prior: Unknown.
//

import Foundation

public enum SeasonalLook: String, Sendable {
    case halloween

    /// Launch-argument key: `-seasonalLook halloween | none`.
    public static let overrideKey = "seasonalLook"

    /// A forced answer from the launch argument.
    public enum Override: Sendable, Equatable {
        case halloween
        case off

        public init?(argument: String?) {
            switch argument?.lowercased() {
            case "halloween": self = .halloween
            case "none": self = .off
            default: return nil
            }
        }

        /// The override in `defaults`' ARGUMENT domain; nil when absent or unrecognised.
        public init?(in defaults: UserDefaults) {
            let raw = defaults.volatileDomain(forName: UserDefaults.argumentDomain)[SeasonalLook.overrideKey]
            self.init(argument: raw as? String)
        }
    }

    /// The look in season on `date` in `calendar`'s time zone, else nil.
    public static func active(on date: Date, calendar: Calendar) -> SeasonalLook? {
        let parts = calendar.dateComponents([.month, .day], from: date)
        guard let month = parts.month, let day = parts.day else { return nil }
        switch (month, day) {
        case (10, 24...), (11, 1): return .halloween
        default: return nil
        }
    }

    /// The look to wear: a launch override wins, then the user's opt-out, then the date.
    public static func resolve(on date: Date, calendar: Calendar, enabled: Bool, override: Override?) -> SeasonalLook? {
        switch override {
        case .halloween: .halloween
        case .off: nil
        case nil: enabled ? active(on: date, calendar: calendar) : nil
        }
    }

    /// The look right now, reading the persisted opt-out (default on) and the argument override.
    public static func current(
        now: Date = Date(), calendar: Calendar = .current, defaults: UserDefaults = .standard
    ) -> SeasonalLook? {
        let enabled = defaults.object(forKey: CompanionDefaults.seasonalLooksKey) as? Bool ?? true
        return resolve(on: now, calendar: calendar, enabled: enabled, override: Override(in: defaults))
    }
}
