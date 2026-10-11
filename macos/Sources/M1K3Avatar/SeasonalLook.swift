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
//  Review: Kev + claude-opus-5.5, 2026-10-11 — review fold: month/day are read on the GREGORIAN
//  calendar in the caller's zone (Calendar.current follows a Hebrew/Islamic/Persian/Chinese
//  regional calendar, whose month 10 is another season); the launch override is read once
//  (`launchOverride`, the avatar resolves ~30 Hz); `now(enabled:)` is the shells' one call, on
//  `.autoupdatingCurrent` so a traveller's zone follows them. Confidence 0.9.
//  Review: Kev + claude-opus-5.5, 2026-10-11 (CI fold) — the costume line moves here from the shared
//  M1K3App/SeasonalGreeting.swift (`greeting(for:)`, tested): a new Mac-shell file compiled by the
//  mobile target is a landing-gate change (MOBILE_PATH_PREFIXES); a package function is not.
//  Confidence 0.9.
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
        // Halloween is a Gregorian date. Keep the caller's time zone, never its calendar system.
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.month, .day], from: date)
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

    /// The one line M1K3 says in costume (at most 70 characters), nil out of season. Copy only:
    /// the persona / system prompt is untouched (prompt edits have measured security costs).
    public static func greeting(for season: SeasonalLook?) -> String? {
        switch season {
        case .halloween:
            String(
                localized: "Happy Halloween! I carved the pumpkin; you bring the questions.",
                comment: "Seasonal greeting shown 24 Oct - 1 Nov. M1K3 is a theatrical villain who is entirely on the user's side; keep it playful and family-safe, one short line."
            )
        case nil:
            nil
        }
    }

    /// The launch-argument override, read once: the argument domain is fixed at launch, and the
    /// avatar resolves the season on every sync.
    public static let launchOverride: Override? = Override(in: .standard)

    /// The look to wear right now — the shells' one call. `enabled` is the Seasonal looks
    /// opt-out the caller already observes (`@AppStorage(CompanionDefaults.seasonalLooksKey)`).
    public static func now(enabled: Bool) -> SeasonalLook? {
        resolve(on: Date(), calendar: .autoupdatingCurrent, enabled: enabled, override: launchOverride)
    }
}
