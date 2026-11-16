//
//  TurnActivityDriver.swift
//  M1K3Chat
//
//  The effect half of the iPhone Live Activity for a long answer or file read, behind two seams so the
//  grace paths are unit-tested: `TurnActivityEffects` (the ActivityKit card, and whether the app is in
//  front) and `BackgroundTaskHosting` (UIApplication's background-task calls). Every decision (start,
//  update, end) is `TurnActivityPolicy`; this class samples the turn, performs what the policy says in
//  order, and holds the background tasks:
//  - GRACE: a turn that runs off this phone's GPU (`BackgroundExitPolicy.wantsBackgroundGrace`) keeps a
//    task so it can finish and flip the card. It ends when the turn ends, on return to the app, or on
//    expiry, where it is ended SYNCHRONOUSLY in the handler (iOS may kill an app that returns first).
//  - PAUSED: the card's "Paused" write for a turn the exit stops has its own short task, so iOS cannot
//    suspend the app before the card changes.
//  A grace task with no card (the app left before the threshold) is kept on purpose: the turn finishes.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-16, Confidence 0.75 (seams and paths unit-tested; the real
//  UIKit/ActivityKit adapters and the grace window are verify-on-device), Prior: none (new file).

import Foundation
import M1K3Inference
import M1K3LiveActivity

/// The card and the app's visibility, as the driver needs them. The app target adapts ActivityKit.
@MainActor
public protocol TurnActivityEffects: AnyObject {
    var appIsActive: Bool { get }
    /// Whether the person allows Live Activities (`ActivityAuthorizationInfo`).
    var activitiesEnabled: Bool { get }
    /// Remove a card left by a process iOS killed: one at a time.
    func endStaleCards() async
    func start(_ state: TurnActivityState)
    func update(_ state: TurnActivityState) async
    func end(final: TurnActivityState?, dismissal: TurnActivityPolicy.Dismissal) async
}

/// `UIApplication.beginBackgroundTask` / `endBackgroundTask`, by token.
@MainActor
public protocol BackgroundTaskHosting: AnyObject {
    /// A token, or nil when iOS refused. `onExpiry` runs on the main actor when the time is up; the task
    /// must be ended before it returns.
    func begin(name: String, onExpiry: @escaping @MainActor () -> Void) -> Int?
    func end(_ token: Int)
}

@MainActor
public final class TurnActivityDriver {
    private var policy = TurnActivityPolicy()
    private let effects: any TurnActivityEffects
    private let tasks: any BackgroundTaskHosting
    private let sampleInterval: Duration
    private var following = false
    private var monitor: Task<Void, Never>?
    private var phase: (@MainActor () -> TurnActivityPhase)?
    private var tail: Task<Void, Never>?
    private var graceToken: Int?
    private var pausedToken: Int?

    public init(
        effects: any TurnActivityEffects, tasks: any BackgroundTaskHosting, sampleInterval: Duration = .seconds(1)
    ) {
        self.effects = effects
        self.tasks = tasks
        self.sampleInterval = sampleInterval
        enqueue { [effects] in await effects.endStaleCards() }
    }

    // MARK: Turn events

    public func turnBegan(phase: @escaping @MainActor () -> TurnActivityPhase) {
        monitor?.cancel()
        self.phase = phase
        following = true
        perform(policy.turnBegan())
        let started = ContinuousClock.now
        let interval = sampleInterval
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self?.sample(elapsed: started.duration(to: .now))
            }
        }
    }

    public func turnFinished(_ outcome: TurnActivityPolicy.Outcome) {
        following = false
        monitor?.cancel()
        monitor = nil
        perform(policy.turnFinished(outcome, appActive: effects.appIsActive))
        // The grace outlives the last effect: the card must say "ready" before iOS may suspend us.
        enqueue { [weak self] in self?.endGrace() }
    }

    /// The app is leaving. Same inputs as `BackgroundExitPolicy.stopsTurn`, so the driver and the stop
    /// can never disagree: an on-device turn gets its Paused card (on its own short task), one that runs
    /// elsewhere gets the grace, and Lil/Big never get one.
    public func leavingForBackground(turnInFlight: Bool, brainRunsOnThisDevicesGPU: Bool) {
        if BackgroundExitPolicy.stopsTurn(turnInFlight: turnInFlight, brainRunsOnThisDevicesGPU: brainRunsOnThisDevicesGPU) {
            pause()
        } else if BackgroundExitPolicy.wantsBackgroundGrace(
            turnInFlight: turnInFlight, brainRunsOnThisDevicesGPU: brainRunsOnThisDevicesGPU
        ) {
            beginGrace()
        }
    }

    public func appBecameActive() {
        endGrace()
        perform(policy.appBecameActive())
    }

    /// One look at the running turn (the monitor's tick; public so tests drive time).
    public func sample(elapsed: Duration) {
        guard following, let phase else { return }
        perform(policy.progress(
            phase: phase(), elapsed: elapsed, appActive: effects.appIsActive, activitiesEnabled: effects.activitiesEnabled
        ))
    }

    /// Resolves when every queued effect has run (tests; nothing in the app waits on it).
    public func settled() async {
        await tail?.value
    }

    // MARK: Background tasks

    private func beginGrace() {
        // Only a turn this driver follows ends the task (`turnFinished`); a voice turn has no such end.
        guard following, graceToken == nil else { return }
        graceToken = tasks.begin(name: "app.m1k3.turn") { [weak self] in self?.graceExpired() }
    }

    /// Time is up and the turn freezes: write Paused best-effort (not awaited), and give the task back
    /// BEFORE returning.
    private func graceExpired() {
        perform(policy.stoppedByBackground())
        endGrace()
    }

    private func endGrace() {
        guard let token = graceToken else { return }
        graceToken = nil
        tasks.end(token)
    }

    /// The exit is stopping an answer made on this phone's GPU: write Paused under its own short task.
    private func pause() {
        let action = policy.stoppedByBackground()
        guard action != .none else { return }
        if pausedToken == nil {
            pausedToken = tasks.begin(name: "app.m1k3.turn.paused") { [weak self] in self?.endPaused() }
        }
        perform(action)
        enqueue { [weak self] in self?.endPaused() }
    }

    private func endPaused() {
        guard let token = pausedToken else { return }
        pausedToken = nil
        tasks.end(token)
    }

    // MARK: Effects

    private func perform(_ action: TurnActivityPolicy.Action) {
        guard action != .none else { return }
        enqueue { [weak self] in await self?.run(action) }
    }

    /// Effects run in order, one at a time, so a start never races the end before it.
    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    private func run(_ action: TurnActivityPolicy.Action) async {
        switch action {
        case .none: break
        case let .start(state): effects.start(state)
        case let .update(state): await effects.update(state)
        case let .end(final, dismissal): await effects.end(final: final, dismissal: dismissal)
        }
    }
}
