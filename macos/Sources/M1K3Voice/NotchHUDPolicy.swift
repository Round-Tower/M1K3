//
//  NotchHUDPolicy.swift
//  M1K3Voice
//
//  Pure policy behind the notch HUD (a heads-up narration pill that appears
//  while M1K3 is talking, promoted from scratch/jam-2026-08-31-2314): the
//  debounced show/hide state machine and the scrolling-marquee travel math.
//  Both proven live in the jam prototype before landing here; the window/
//  RealityKit/SwiftUI glue that consumes them lives in M1K3App and is
//  verify-by-launch (this repo's metallib-wall convention).
//
//  Signed: Kev + claude-fable-5, 2026-09-01, Confidence 0.85 (the debounce and
//  marquee math are the exact shapes proven live in the jam — the 0.7s grace
//  and the +16pt trailing pad — now unit-pinned instead of eyeballed).
//  Prior: the jam's AppDelegate.tick()/MarqueeText.restart(), same session.
//  Review: Kev + claude-fable-5.1, 2026-09-12 — `awaitsGrace` exposes the one
//  window the driver must poll through; the controller now sleeps on the
//  observable speech signal otherwise. Confidence now 0.85.
//  Review: Kev + claude-fable-5.1, 2026-09-12 (#293 pass 7) — `wakeValve(speaking:)`: the drive loop's
//  signal valve is 1 s while speech is live (the un-observed Settings toggle is re-read then) and 30 s idle.
//  Confidence now 0.85.
//

import Foundation

/// Debounces a raw, flappy "is M1K3 speaking" signal into a stable show/hide
/// decision. Kokoro's own `speaking` status genuinely toggles true/false every
/// ~150-300ms BETWEEN spoken sentences within one answer (confirmed live,
/// repeatedly, in the jam) — reacting to the raw signal directly makes a
/// fading-in HUD retreat before its animation can even finish. This only
/// reports an action on an actual state CHANGE, and requires `hideGraceSeconds`
/// of continuous silence before hiding.
public struct NotchHUDVisibility: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case show
        case hide
    }

    /// How long the signal must stay false before this actually hides —
    /// 0.7s in the jam, comfortably past the widest observed inter-sentence gap.
    public let hideGraceSeconds: Double
    public private(set) var isShown = false
    private var falseSinceSeconds: Double?

    /// True while the HUD is shown and the signal has gone quiet but the grace
    /// hasn't elapsed — the ONE interval the driver must tick on a clock,
    /// because no change in the signal will arrive to wake it. Everywhere
    /// else the driver can sleep until the (observable) signal changes.
    /// (2026-09-12 thermal audit: this replaces a lifetime 10 Hz poll.)
    public var awaitsGrace: Bool {
        isShown && falseSinceSeconds != nil
    }

    /// How long the drive loop may sleep on the speech signal before it
    /// re-reads its inputs anyway. Speech itself wakes the loop by
    /// observation; the Settings toggle does not (it is an `@AppStorage`
    /// value, not an observed one), so while speech is live the valve is
    /// short enough that a flip shows or hides the HUD within a second — a
    /// 1 Hz tick beside a 14 fps creature costs nothing. Idle, nothing can
    /// change what the loop would do until speech starts, so the valve is
    /// only a safety net against a missed observation.
    public static func wakeValve(speaking: Bool) -> Duration {
        speaking ? .seconds(1) : .seconds(30)
    }

    public init(hideGraceSeconds: Double = 0.7) {
        self.hideGraceSeconds = hideGraceSeconds
    }

    /// Feed the current raw signal and a monotonic clock reading (seconds,
    /// any epoch — only differences matter). Returns the action to take now,
    /// or nil when nothing should change.
    @discardableResult
    public mutating func update(speaking: Bool, atSeconds now: Double) -> Action? {
        if speaking {
            falseSinceSeconds = nil
            guard !isShown else { return nil }
            isShown = true
            return .show
        }
        guard isShown else { return nil }
        if falseSinceSeconds == nil {
            falseSinceSeconds = now
        }
        guard let since = falseSinceSeconds, now - since >= hideGraceSeconds else { return nil }
        isShown = false
        falseSinceSeconds = nil
        return .hide
    }
}

/// Scrolling-marquee travel/duration math for narration text too wide for its
/// viewport — pure geometry, no SwiftUI dependency, so the constant (the 16pt
/// trailing pad, the fits-so-don't-scroll floor) is pinned once instead of
/// living only inside a `View`.
public enum MarqueeMetrics {
    /// nil when `textWidth` already fits `viewportWidth` (no scrolling needed)
    /// or `pointsPerSecond` isn't positive (nothing to divide by). Otherwise the
    /// points to travel (the overflow plus a small trailing pad so the last
    /// character fully clears the viewport before looping) and how long that
    /// travel takes at the given speed.
    public static func plan(
        textWidth: Double,
        viewportWidth: Double,
        pointsPerSecond: Double = 45
    ) -> (travel: Double, duration: Double)? {
        guard textWidth > viewportWidth, pointsPerSecond > 0 else { return nil }
        let travel = textWidth - viewportWidth + 16
        return (travel, travel / pointsPerSecond)
    }

    /// Where the reading zone ends, as a fraction of the viewport: the line
    /// scrolls only once the spoken word would pass this point, so a listener
    /// sees the word with the words after it still coming.
    public static let readingZone = 0.72

    /// The horizontal offset (≤ 0) that keeps the word ending at UTF-16 unit
    /// `wordEnd` of a `lineLength`-unit line inside the reading zone, with the
    /// word's x estimated proportionally along `textWidth`. 0 while the text
    /// fits or the word is still inside the zone; never further than the
    /// overflow plus the trailing pad (`plan`'s travel). The view is expected
    /// to hold the offset monotone — a caption never scrolls backwards.
    public static func followOffset(
        wordEnd: Int,
        lineLength: Int,
        textWidth: Double,
        viewportWidth: Double
    ) -> Double {
        guard textWidth > viewportWidth else { return 0 }
        let fraction = lineLength > 0 ? min(max(Double(wordEnd) / Double(lineLength), 0), 1) : 1
        let wordEndX = textWidth * fraction
        let zoneEdge = viewportWidth * readingZone
        let travel = textWidth - viewportWidth + 16
        return max(min(0, zoneEdge - wordEndX), -travel)
    }
}
