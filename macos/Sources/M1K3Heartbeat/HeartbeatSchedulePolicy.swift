//
//  HeartbeatSchedulePolicy.swift
//  M1K3Heartbeat
//
//  The pure "does a pulse fire now?" decision. The app owns the effects
//  (a coarse check loop + the live busy/thermal reads); this type owns the
//  ordering, which the log line reports: quiet hours first (cheapest, no
//  work at night), then cadence, then busy, then thermal. A future
//  watermark — clock skew, a timezone flight — clamps to due-now rather
//  than wedging the heartbeat until the wall clock catches up (challenger
//  finding, pinned).
//
//  `hour` is passed in rather than derived so the type stays Calendar-free
//  and deterministic under test; the caller computes it in local time.
//
//  Signed: Kev + claude-fable-5, 2026-08-06, Confidence 0.9 (pure policy,
//  every branch pinned). Prior: none (new file).
//

import Foundation

/// Why a due check declined to pulse — the skip is logged (reason only,
/// never content) so a silent afternoon is explicable from the log stream.
public enum HeartbeatSkipReason: String, Sendable, Equatable {
    case tooSoon = "too-soon"
    case quietHours = "quiet-hours"
    case machineBusy = "machine-busy"
    case thermal
}

public enum HeartbeatDecision: Sendable, Equatable {
    case fire
    case skip(HeartbeatSkipReason)
}

/// A daily do-not-disturb window in local wall-clock hours, half-open
/// [startHour, endHour), wrapping midnight when startHour > endHour.
/// startHour == endHour means the window is empty (never quiet).
public struct QuietHours: Sendable, Equatable {
    public var startHour: Int
    public var endHour: Int

    /// 23:00 through 07:59 — nobody needs a status update at 3am.
    public static let standard = QuietHours(startHour: 23, endHour: 8)

    public init(startHour: Int, endHour: Int) {
        self.startHour = startHour
        self.endHour = endHour
    }

    public func contains(hour: Int) -> Bool {
        if startHour == endHour { return false }
        if startHour < endHour { return hour >= startHour && hour < endHour }
        return hour >= startHour || hour < endHour
    }
}

public struct HeartbeatSchedulePolicy: Sendable, Equatable {
    /// "Every couple of hours" — Kev's cadence, a decision not a setting
    /// (doctrine principle 4).
    public var interval: TimeInterval
    public var quietHours: QuietHours

    public init(interval: TimeInterval = 2 * 60 * 60, quietHours: QuietHours = .standard) {
        self.interval = interval
        self.quietHours = quietHours
    }

    public func decide(
        now: Date,
        hour: Int,
        lastPulse: Date?,
        isBusy: Bool,
        backgroundAllowed: Bool
    ) -> HeartbeatDecision {
        if quietHours.contains(hour: hour) { return .skip(.quietHours) }
        if let lastPulse, lastPulse <= now, now.timeIntervalSince(lastPulse) < interval {
            return .skip(.tooSoon)
        }
        if isBusy { return .skip(.machineBusy) }
        if !backgroundAllowed { return .skip(.thermal) }
        return .fire
    }
}

/// The anti-noise rule: a quiet window records no pulse, except the day's
/// first — the surface never nags, never goes fully silent.
public enum HeartbeatEmptyRule {
    public static func shouldPulse(hasActivity: Bool, isFirstPulseToday: Bool) -> Bool {
        hasActivity || isFirstPulseToday
    }
}
