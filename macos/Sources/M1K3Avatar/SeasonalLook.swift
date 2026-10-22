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
//  Offline AI Flight Club: Nov 3 00:00 through Dec 1 23:59:59 (same local-Gregorian rules), but
//  ONLY while the device is offline — the companion wears flight colours and the greeting says it
//  keeps working. The network signal is an INPUT (`offline:`), never read here: the shells pass
//  `NetworkPathWatch.shared.isOffline`, so this file stays pure and the gate is unit-tested.
//
//  Launch argument: `M1K3 -seasonalLook halloween | flightclub` forces the look on (flightclub
//  regardless of date AND network), `-seasonalLook none` forces it off (screenshots, store art,
//  verification). Read from the ARGUMENT domain only, like `GenerationActivity.isEnabled`: on
//  macOS 27 `defaults write` never reaches the sandboxed app, and a persisted key must never force
//  a look in a shipped build.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.85 (pure date maths pinned by
//  tests; the on-screen look is verify-by-launch). Prior: Unknown.
//  Review: Kev + claude-opus-5.5, 2026-10-11 — review fold: month/day are read on the GREGORIAN
//  calendar in the caller's zone (Calendar.current follows a Hebrew/Islamic/Persian/Chinese
//  regional calendar, whose month 10 is another season); the launch override is read once
//  (`launchOverride`, the avatar resolves ~30 Hz); `now(enabled:offline:)` is the shells' one call, on
//  `.autoupdatingCurrent` so a traveller's zone follows them. Confidence 0.9.
//  Review: Kev + claude-opus-5.5, 2026-10-11 (CI fold) — the costume line moves here from the shared
//  M1K3App/SeasonalGreeting.swift (`greeting(for:)`, tested): a new Mac-shell file compiled by the
//  mobile target is a landing-gate change (MOBILE_PATH_PREFIXES); a package function is not.
//  Confidence 0.9.
//  Review: Kev + claude-sonnet-5.5, 2026-10-22 — Offline AI Flight Club: `.flightClub` (Nov 3 – Dec 1, offline
//  only, Halloween checked first), `Override.flightClub`, and a REQUIRED `offline:` on active / resolve / now
//  (no default, so the compiler finds every call site). Copy promises only what ships: flight colours + one
//  greeting while offline. Confidence 0.85 (maths pinned; the look and real Airplane Mode are verify-on-device).
//

import Foundation

public enum SeasonalLook: String, Sendable {
    case halloween
    /// Offline AI Flight Club — Nov 3 – Dec 1, only while offline.
    case flightClub = "flightclub"

    /// Launch-argument key: `-seasonalLook halloween | flightclub | none`.
    public static let overrideKey = "seasonalLook"

    /// A forced answer from the launch argument.
    public enum Override: Sendable, Equatable {
        case halloween
        case flightClub
        case off

        public init?(argument: String?) {
            switch argument?.lowercased() {
            case "halloween": self = .halloween
            case "flightclub": self = .flightClub
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

    /// The look in season on `date` in `calendar`'s time zone, else nil. `offline` gates Flight Club
    /// only; Halloween is date-only and is checked first (the windows never overlap anyway).
    public static func active(on date: Date, calendar: Calendar, offline: Bool) -> SeasonalLook? {
        // Halloween is a Gregorian date. Keep the caller's time zone, never its calendar system.
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.month, .day], from: date)
        guard let month = parts.month, let day = parts.day else { return nil }
        switch (month, day) {
        case (10, 24...), (11, 1): return .halloween
        case (11, 3...), (12, 1): return offline ? .flightClub : nil
        default: return nil
        }
    }

    /// The look to wear: a launch override wins (regardless of date and network), then the user's
    /// opt-out, then the date and the network.
    public static func resolve(on date: Date, calendar: Calendar, enabled: Bool, offline: Bool, override: Override?) -> SeasonalLook? {
        switch override {
        case .halloween: .halloween
        case .flightClub: .flightClub
        case .off: nil
        case nil: enabled ? active(on: date, calendar: calendar, offline: offline) : nil
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
        case .flightClub:
            String(
                localized: "Offline? I'm still right here, on your device.",
                comment: "Seasonal greeting shown 3 Nov - 1 Dec, ONLY while the device is offline (Offline AI Flight Club). M1K3 is a theatrical villain who is entirely on the user's side; keep it playful, honest (it must be true when offline, even with no brain downloaded yet, so it promises presence, never answers) and family-safe, one short line of at most 70 characters."
            )
        case nil:
            nil
        }
    }

    /// The launch-argument override, read once: the argument domain is fixed at launch, and the
    /// avatar resolves the season on every sync.
    public static let launchOverride: Override? = Override(in: .standard)

    /// The look to wear right now — the shells' one call. `enabled` is the Seasonal looks
    /// opt-out the caller already observes (`@AppStorage(CompanionDefaults.seasonalLooksKey)`);
    /// `offline` is `NetworkPathWatch.shared.isOffline`, read where the view observes it.
    public static func now(enabled: Bool, offline: Bool) -> SeasonalLook? {
        resolve(on: Date(), calendar: .autoupdatingCurrent, enabled: enabled, offline: offline, override: launchOverride)
    }
}
