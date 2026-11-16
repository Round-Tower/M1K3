//
//  TurnActivityPolicy.swift
//  M1K3Chat
//
//  The lifecycle of the iPhone's Live Activity for a long answer or a file read, as a pure value:
//  events in, an `Action` out, and the app target performs the ActivityKit effect (request,
//  update, end). Pure so every rule is unit-tested away from ActivityKit.
//
//  The rules:
//  - START when a turn is still running at `TurnNotificationPolicy.longTurnThreshold` (the same
//    "long" the notification uses), the app is in the FOREGROUND (`Activity.request` only works
//    from there) and the person has Live Activities on. One activity at a time.
//  - UPDATE on a phase change, at most once per `minimumUpdateInterval`; a change held back by the
//    throttle is sent at the next look, not lost.
//  - END: "Answer ready" when the answer lands while the app is away (the card lingers a while);
//    at once when the app is in front (the answer is already on screen), and on failure, the
//    user's stop or a new chat. "Paused" when an answer on this phone's GPU is stopped by the
//    background exit (`BackgroundExitPolicy`): opening M1K3 is the way back.
//
//  Content is the phase, never the turn (`TurnActivityState`).
//
//  Signed: Kev + claude-opus-5.5, 2026-11-16, Confidence 0.8 (the rules are pinned in
//  TurnActivityPolicyTests; the intervals are by-feel defaults, tune on a real phone),
//  Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-11-16 — `leavingForeground`: the card also starts when the app goes
//  inactive mid-turn, at any elapsed time (Kev's phone: a 6 s Mini turn got no card, and none can start from the
//  background). A card started that way is taken down again when the app is active (a Control Center pull
//  leaves nothing behind); the 8 s start stays as the backstop. Confidence 0.75 (pinned; the device is the test).

import Foundation
import M1K3LiveActivity

public struct TurnActivityPolicy: Sendable {
    /// What the app target should do to the ONE activity.
    public enum Action: Sendable, Equatable {
        case none
        case start(TurnActivityState)
        case update(TurnActivityState)
        /// `final` is the content the card keeps showing until `dismissal`; nil ends it with nothing to show.
        case end(final: TurnActivityState?, dismissal: Dismissal)
    }

    public enum Dismissal: Sendable, Equatable {
        case immediate
        case after(Duration)
    }

    /// How a turn left the stage.
    public enum Outcome: Sendable, Equatable {
        case answered
        case failed
        /// The user's own stop, or a turn that left nothing.
        case stopped
        case newChat
    }

    /// Why `leavingForeground` did or did not start a card (the app logs it).
    public enum LeaveReason: Sendable, Equatable {
        case started
        case alreadyShown
        case noTurn
        case disabled
    }

    /// Phase changes reach the Lock Screen at most this often (ActivityKit budgets updates).
    public static let minimumUpdateInterval: Duration = .seconds(2)
    /// How long "Answer ready" stays on the Lock Screen when nobody opens the app.
    public static let readyLingers: Duration = .seconds(15 * 60)
    /// How long "Paused" stays: the turn cannot resume by itself, so it is a pointer back, not a record.
    public static let pausedLingers: Duration = .seconds(30 * 60)

    private var turnRunning = false
    /// What the activity on screen shows; nil when there is none.
    private var shown: TurnActivityState?
    private var lastSentAt: Duration = .zero
    /// One card per turn: once it has been shown (and ended by a return to the app), the same turn never
    /// starts another in front of the answer it is already streaming into.
    private var cardShownThisTurn = false
    /// The card on screen was started by `leavingForeground`, a hedge that a return to the app undoes.
    private var startedWhileLeaving = false

    public init() {}

    /// A turn started. A lingering Ready/Paused card from an earlier turn ends first.
    public mutating func turnBegan() -> Action {
        turnRunning = true
        cardShownThisTurn = false
        startedWhileLeaving = false
        guard let shown, shown.phase == .ready || shown.phase == .paused else { return .none }
        self.shown = nil
        return .end(final: nil, dismissal: .immediate)
    }

    /// A look at the running turn: `elapsed` since it began, the `phase` it is in now.
    public mutating func progress(
        phase: TurnActivityPhase, elapsed: Duration, appActive: Bool, activitiesEnabled: Bool
    ) -> Action {
        guard turnRunning else { return .none }
        guard let current = shown else {
            guard !cardShownThisTurn, appActive, activitiesEnabled, elapsed >= TurnNotificationPolicy.longTurnThreshold else { return .none }
            let next = TurnActivityState(phase: phase)
            shown = next
            cardShownThisTurn = true
            lastSentAt = elapsed
            return .start(next)
        }
        guard current.phase != .ready, current.phase != .paused else { return .none }
        guard phase != current.phase, elapsed - lastSentAt >= Self.minimumUpdateInterval else { return .none }
        let next = TurnActivityState(phase: phase)
        shown = next
        lastSentAt = elapsed
        return .update(next)
    }

    /// The app is leaving the foreground (`scenePhase` .inactive) with a turn possibly in flight. An app's own
    /// card is only seen once you have left, and `Activity.request` is refused from the background, so the
    /// card starts NOW, whatever the elapsed time ("ask, then lock the phone" is mostly under 8 s). The 8 s
    /// start in `progress` stays as the backstop for a long turn left in front.
    public mutating func leavingForeground(
        phase: TurnActivityPhase, activitiesEnabled: Bool
    ) -> (action: Action, reason: LeaveReason) {
        guard turnRunning else { return (.none, .noTurn) }
        guard shown == nil else { return (.none, .alreadyShown) }
        guard activitiesEnabled else { return (.none, .disabled) }
        let next = TurnActivityState(phase: phase)
        shown = next
        cardShownThisTurn = true
        startedWhileLeaving = true
        lastSentAt = .zero
        return (.start(next), .started)
    }

    /// The turn left the stage.
    public mutating func turnFinished(_ outcome: Outcome, appActive: Bool) -> Action {
        turnRunning = false
        startedWhileLeaving = false
        guard let current = shown else { return .none }
        // The stop that follows `stoppedByBackground` is the same turn ending: the Paused card stays.
        if current.phase == .paused, outcome == .stopped || outcome == .failed { return .none }
        if outcome == .answered, !appActive {
            let ready = TurnActivityState(phase: .ready)
            shown = ready
            return .end(final: ready, dismissal: .after(Self.readyLingers))
        }
        shown = nil
        return .end(final: nil, dismissal: .immediate)
    }

    /// The background exit stopped an answer made on this phone's GPU. Only a card already on screen can
    /// say so: a card cannot be started from the background.
    public mutating func stoppedByBackground() -> Action {
        guard turnRunning, let current = shown, current.phase != .ready, current.phase != .paused else { return .none }
        let paused = TurnActivityState(phase: .paused)
        shown = paused
        return .end(final: paused, dismissal: .after(Self.pausedLingers))
    }

    /// The app came to the front: a lingering Ready/Paused card has done its job.
    public mutating func appBecameActive() -> Action {
        guard let current = shown else { return .none }
        // A card started on the way out is undone by the way back (a Control Center pull leaves nothing behind).
        let lingering = current.phase == .ready || current.phase == .paused
        guard lingering || startedWhileLeaving else { return .none }
        startedWhileLeaving = false
        shown = nil
        return .end(final: nil, dismissal: .immediate)
    }
}
