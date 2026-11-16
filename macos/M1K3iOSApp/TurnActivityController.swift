//
//  TurnActivityController.swift
//  M1K3iOS
//
//  The effect half of the iPhone Live Activity for a long answer or file read. Every decision (when to
//  start, update, end) is `TurnActivityPolicy` in M1K3Chat; this class samples the turn once a second,
//  performs what the policy says through ActivityKit, and holds the background-task grace that lets an
//  off-GPU turn (Mini, Brain at Home, Private Cloud) finish while the app is away.
//
//  Content is the phase only (`TurnActivityState`), updated locally: no push token, no server. Effects run
//  one after another on a serial chain, so a start never races the end before it.
//
//  iOS only. visionOS has no ActivityKit: the type exists there as an inert shell so AppCore needs no #if.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-16, Confidence 0.7 (compile-checked; the card's look and the
//  grace window are verify-on-device), Prior: none (new file).

import Foundation
import M1K3Chat
import M1K3LiveActivity
import M1K3LogCore
#if os(iOS)
    import ActivityKit
    import UIKit
#endif

@MainActor
final class TurnActivityController {
    enum Kind { case answer, read }

    #if os(iOS)
        private static let log = M1K3Log.logger(.iosCore)

        private var policy = TurnActivityPolicy()
        private var monitor: Task<Void, Never>?
        private var startedAt: ContinuousClock.Instant?
        private var phase: (@MainActor () -> TurnActivityPhase)?
        private var tail: Task<Void, Never>?
        private var grace: UIBackgroundTaskIdentifier = .invalid

        init() {
            // A card from a process iOS killed (a memory kill mid-answer) would outlive its turn: one at a time.
            enqueue { await Self.endAll(nil, .immediate) }
        }

        // MARK: Turn events

        func turnBegan(kind _: Kind, phase: @escaping @MainActor () -> TurnActivityPhase) {
            monitor?.cancel()
            self.phase = phase
            startedAt = .now
            perform(policy.turnBegan())
            monitor = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    self?.sample()
                }
            }
        }

        func turnFinished(_ outcome: TurnActivityPolicy.Outcome) {
            monitor?.cancel()
            monitor = nil
            perform(policy.turnFinished(outcome, appActive: Self.appIsActive))
            // The grace outlives the last effect: the card must say "ready" before iOS may suspend us.
            enqueue { [weak self] in self?.endGrace() }
        }

        /// The background exit is stopping an answer made on this phone's GPU: the card says so.
        func stoppedByBackground() {
            perform(policy.stoppedByBackground())
        }

        func appBecameActive() {
            endGrace()
            perform(policy.appBecameActive())
        }

        // MARK: Background grace

        /// Hold a background task so an off-GPU turn can finish and flip the card to "Answer ready".
        /// The caller decides with `BackgroundExitPolicy.wantsBackgroundGrace`, never for Lil/Big.
        func beginGrace() {
            // Only a turn this controller follows ends the task (`turnFinished`); a voice turn has no such end.
            guard monitor != nil, grace == .invalid else { return }
            grace = UIApplication.shared.beginBackgroundTask(withName: "app.m1k3.turn") { [weak self] in
                // The time is up and the turn freezes: say so, then give the task back.
                MainActor.assumeIsolated {
                    self?.stoppedByBackground()
                    self?.enqueue { [weak self] in self?.endGrace() }
                }
            }
        }

        private func endGrace() {
            guard grace != .invalid else { return }
            UIApplication.shared.endBackgroundTask(grace)
            grace = .invalid
        }

        // MARK: Sampling and effects

        private static var appIsActive: Bool {
            UIApplication.shared.applicationState == .active
        }

        private func sample() {
            guard let startedAt, let phase else { return }
            let action = policy.progress(
                phase: phase(), elapsed: startedAt.duration(to: .now),
                appActive: Self.appIsActive,
                activitiesEnabled: ActivityAuthorizationInfo().areActivitiesEnabled
            )
            perform(action)
        }

        private func perform(_ action: TurnActivityPolicy.Action) {
            guard action != .none else { return }
            enqueue { [weak self] in await self?.run(action) }
        }

        /// Effects run in order, one at a time.
        private func enqueue(_ work: @escaping @MainActor () async -> Void) {
            let previous = tail
            tail = Task { @MainActor in
                await previous?.value
                await work()
            }
        }

        private func run(_ action: TurnActivityPolicy.Action) async {
            switch action {
            case .none:
                break
            case let .start(state):
                do {
                    _ = try Activity.request(
                        attributes: TurnActivityAttributes(),
                        content: ActivityContent(state: state, staleDate: nil),
                        pushType: nil
                    )
                } catch {
                    // Refused (the person switched it off, too many cards): the turn goes on without one.
                    Self.log.notice("live activity not started: \(String(describing: error), privacy: .public)")
                }
            case let .update(state):
                await Self.updateAll(ActivityContent(state: state, staleDate: nil))
            case let .end(final, dismissal):
                let content = final.map { ActivityContent(state: $0, staleDate: nil) }
                await Self.endAll(content, Self.policy(for: dismissal))
            }
        }

        /// The card is addressed through ActivityKit's own list, inside a nonisolated function: an `Activity`
        /// is not Sendable, so it never crosses out of the main actor. The policy keeps it to one card.
        private nonisolated static func updateAll(_ content: ActivityContent<TurnActivityState>) async {
            for card in Activity<TurnActivityAttributes>.activities {
                await card.update(content)
            }
        }

        private nonisolated static func endAll(
            _ content: ActivityContent<TurnActivityState>?, _ dismissal: ActivityUIDismissalPolicy
        ) async {
            for card in Activity<TurnActivityAttributes>.activities {
                await card.end(content, dismissalPolicy: dismissal)
            }
        }

        private static func policy(for dismissal: TurnActivityPolicy.Dismissal) -> ActivityUIDismissalPolicy {
            switch dismissal {
            case .immediate: .immediate
            case let .after(duration): .after(Date(timeIntervalSinceNow: Double(duration.components.seconds)))
            }
        }
    #else
        func turnBegan(kind _: Kind, phase _: @escaping @MainActor () -> TurnActivityPhase) {}
        func turnFinished(_: TurnActivityPolicy.Outcome) {}
        func stoppedByBackground() {}
        func appBecameActive() {}
        func beginGrace() {}
    #endif
}
