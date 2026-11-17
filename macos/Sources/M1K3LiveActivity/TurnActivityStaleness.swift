//
//  TurnActivityStaleness.swift
//  M1K3LiveActivity
//
//  A card the app can no longer update. iOS kills a backgrounded app (memory pressure, a crash) without
//  warning, and a card the dead process had written as "thinking…" said so forever: Paused and Ready are
//  written by the living app, so nothing would ever replace it. ActivityKit's own answer is the stale date:
//  every working card carries one, the app re-writes it while it is alive (each phase, and the start of the
//  background grace), and once it passes the widget draws an honest "stopped updating" look instead.
//
//  The window outlasts the background grace (about 30 s on iOS 27), so a turn that is still running is never
//  shown stale; a settled card (Ready, Paused) has no stale date, because it already says the last true thing.
//  A card in FRONT whose phase holds for two minutes goes stale too, unseen: the app's own card is not drawn while
//  it is in front, and leaving re-writes it (the grace) or settles it (Paused) before anyone can look.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-17, Confidence 0.8 (pure and tested; the stale look itself is owed
//  on a phone: kill the app from Xcode mid-turn in the background and wait two minutes).
//  Prior: none (new file).
//

import Foundation

public enum TurnActivityStaleness {
    /// Seconds after the last write that a working card goes stale.
    public static let after: TimeInterval = 120

    /// The brain is still at work on this card (as opposed to Ready or Paused, which are settled).
    public static func isWorking(_ phase: TurnActivityPhase) -> Bool {
        switch phase {
        case .thinking, .reading, .answering: true
        case .ready, .paused: false
        }
    }

    /// The stale date to write with `state` at `now`: nil for a settled card.
    public static func staleDate(for state: TurnActivityState, now: Date) -> Date? {
        isWorking(state.phase) ? now.addingTimeInterval(after) : nil
    }

    /// The face a card shows: a stale working card shuts its eyes (the Paused face), everything else is itself.
    public static func facePhase(_ phase: TurnActivityPhase, isStale: Bool) -> TurnActivityPhase {
        isStale && isWorking(phase) ? .paused : phase
    }
}
