//
//  OnboardingTrace.swift
//  M1K3LogCore
//
//  The onboarding sheet's stopwatch (Kev, TestFlight 2026-10-11: "Re-run onboarding… was slow").
//  The Re-run button arms it; every breadcrumb after (sheet first appear, backdrop companion
//  ready, phase changes) logs `.notice` with the milliseconds since the tap, so the next build's
//  log says where the time goes. Unarmed (the first-run window, the live chat backdrop) it logs
//  nothing. The clock is injected so the arithmetic is pinned without sleeping.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.85 (the clock is tested; which marks
//  matter is a guess until the first TestFlight log). Prior: none (new file).

import Foundation
import os
import Synchronization

public final class OnboardingTrace: Sendable {
    public static let shared = OnboardingTrace()

    private struct State {
        var start: ContinuousClock.Instant?
        var claimed: Set<String> = []
    }

    private let state = Mutex(State())
    private static let log = M1K3Log.logger(.onboarding)

    public init() {}

    /// Arm the stopwatch at the Re-run tap; re-arms the once-claims.
    public func begin(at instant: ContinuousClock.Instant = .now) {
        state.withLock { $0 = State(start: instant) }
        Self.log.notice("onboarding trace: re-run tapped (t=0 ms)")
    }

    public func end() {
        state.withLock { $0 = State() }
    }

    /// Whole milliseconds since `begin`, or nil when unarmed.
    public func elapsedMilliseconds(at instant: ContinuousClock.Instant = .now) -> Int? {
        state.withLock { current in
            guard let start = current.start else { return nil }
            let parts = (instant - start).components
            return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
        }
    }

    /// True the first time `event` is claimed since `begin`; false when unarmed or already
    /// claimed (a once-mark for events a view may repeat).
    public func claim(_ event: String) -> Bool {
        state.withLock { current in
            guard current.start != nil else { return false }
            return current.claimed.insert(event).inserted
        }
    }

    /// A `.notice` breadcrumb with elapsed ms since the tap; silent when unarmed.
    public func mark(_ event: String) {
        guard let elapsed = elapsedMilliseconds() else { return }
        Self.log.notice("onboarding trace: \(event, privacy: .public) +\(elapsed, privacy: .public) ms")
    }

    /// `mark`, at most once per tap.
    public func markOnce(_ event: String) {
        guard claim(event) else { return }
        mark(event)
    }
}
