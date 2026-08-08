//
//  HeartbeatHoldLine.swift
//  M1K3Heartbeat
//
//  The honest-hold resolver. The schedule policy skips pulses for good
//  reasons (quiet hours, a warm machine, a busy machine) and the empty rule
//  withholds quiet windows — but a skipped pulse used to be invisible: the
//  surfaces showed an ageing "6 hours ago" that read as "the heartbeat is
//  broken" (2026-08-08 live finding: 47 quiet-hour + 3 thermal skips in one
//  night, all silent). Graceful degradation indistinguishable from failure
//  is a design bug — this type turns the last hold into one short, honest
//  line for the idle card and the Heartbeat window.
//
//  Pure and Calendar-free like HeartbeatSchedulePolicy: `hour` is passed in
//  (local time, computed by the caller) so every branch is deterministic
//  under test.
//
//  Signed: Kev + claude-fable-5, 2026-08-08, Confidence 0.9 (pure resolver,
//  every branch pinned red-first; the rendered feel on the card is ⌘R
//  verify-owed). Prior: none (new file).
//

import Foundation

/// Why the heartbeat is holding — the surfaced counterpart of
/// `HeartbeatSkipReason`, plus the empty rule's quiet-window withhold
/// (which is a decision the schedule policy never sees).
public enum HeartbeatHoldReason: String, Sendable, Equatable {
    case quietHours = "quiet-hours"
    case machineBusy = "machine-busy"
    case thermal
    case quietWindow = "quiet-window"

    /// A skip becomes a hold; `tooSoon` is not a hold (the pulse is fresh).
    public init?(skip: HeartbeatSkipReason) {
        switch skip {
        case .tooSoon: return nil
        case .quietHours: self = .quietHours
        case .machineBusy: self = .machineBusy
        case .thermal: self = .thermal
        }
    }
}

/// The engine's record of the most recent hold — reason plus when the
/// check loop declined, so a hold that stopped refreshing (the machine
/// slept, the loop is gone) ages out instead of explaining forever.
public struct HeartbeatHold: Sendable, Equatable {
    public var reason: HeartbeatHoldReason
    public var at: Date

    public init(reason: HeartbeatHoldReason, at: Date) {
        self.reason = reason
        self.at = at
    }
}

public enum HeartbeatHoldLine {
    /// A pulse is "stale" only past interval + this slack — the loop ticks
    /// coarsely, so a pulse a few minutes over its cadence is normal life,
    /// not a hold worth explaining.
    public static let staleSlack: TimeInterval = 30 * 60
    /// A hold only explains while the loop is actively refreshing it
    /// (ticks are 10-minutely; 30 min covers jitter). Older holds mean the
    /// loop itself went quiet — usually system sleep — and a confident
    /// explanation would be a guess.
    public static let holdRecency: TimeInterval = 30 * 60

    /// One short line for the heartbeat surfaces, or nil when the latest
    /// pulse speaks for itself (fresh, or nothing honest to say).
    public static func resolve(
        now: Date,
        hour: Int,
        lastPulse: Date?,
        lastHold: HeartbeatHold?,
        interval: TimeInterval = HeartbeatSchedulePolicy().interval,
        quietHours: QuietHours = .standard
    ) -> String? {
        // A fresh (or future-dated, clock-skewed) pulse needs no excuse.
        if let lastPulse, now.timeIntervalSince(lastPulse) < interval + staleSlack {
            return nil
        }
        if quietHours.contains(hour: hour) {
            return "Quiet hours — the next pulse comes with the morning."
        }
        if let lastHold, now.timeIntervalSince(lastHold.at) <= holdRecency {
            switch lastHold.reason {
            case .thermal:
                return "Holding off while the machine runs warm."
            case .machineBusy:
                return "Holding off while the machine is busy."
            case .quietWindow:
                return "A quiet stretch — I'll pulse when something happens, or with the morning."
            case .quietHours:
                // Quiet hours ended but the hold hasn't refreshed yet — the
                // loop fires within minutes; don't explain a night that's over.
                return nil
            }
        }
        if lastPulse == nil {
            return "The first pulse is on its way."
        }
        return nil
    }
}
