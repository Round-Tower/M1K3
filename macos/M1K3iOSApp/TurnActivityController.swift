//
//  TurnActivityController.swift
//  M1K3iOS
//
//  The real adapters under `TurnActivityDriver` (M1K3Chat, where the lifecycle and the grace paths are
//  unit-tested): ActivityKit for the card, UIApplication for the background tasks. Content is the phase
//  only (`TurnActivityState`), updated locally: no push token, no server.
//
//  iOS only. visionOS has no ActivityKit: there the adapters are inert (no card, no task), so AppCore
//  needs no #if.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-16, Confidence 0.7 (compile-checked; the card's look and the
//  grace window are verify-on-device), Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-11-16 (code-quality review) — the controller became these thin
//  adapters; the lifecycle moved into the tested TurnActivityDriver. The expiry handler now ends its task
//  synchronously and the Paused write holds its own short task.

import Foundation
import M1K3Chat
import M1K3LiveActivity
import M1K3LogCore
#if os(iOS)
    import ActivityKit
    import UIKit
#endif

extension TurnActivityDriver {
    static func live() -> TurnActivityDriver {
        TurnActivityDriver(effects: ActivityKitEffects(), tasks: UIKitBackgroundTasks())
    }
}

#if os(iOS)
    @MainActor
    final class ActivityKitEffects: TurnActivityEffects {
        private static let log = M1K3Log.logger(.iosCore)

        var appIsActive: Bool {
            UIApplication.shared.applicationState == .active
        }

        var activitiesEnabled: Bool {
            ActivityAuthorizationInfo().areActivitiesEnabled
        }

        func endStaleCards() async {
            await Self.endAll(nil, .immediate)
        }

        func start(_ state: TurnActivityState) {
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
        }

        func update(_ state: TurnActivityState) async {
            await Self.updateAll(ActivityContent(state: state, staleDate: nil))
        }

        func end(final: TurnActivityState?, dismissal: TurnActivityPolicy.Dismissal) async {
            await Self.endAll(final.map { ActivityContent(state: $0, staleDate: nil) }, Self.policy(for: dismissal))
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
    }

    @MainActor
    final class UIKitBackgroundTasks: BackgroundTaskHosting {
        func begin(name: String, onExpiry: @escaping @MainActor () -> Void) -> Int? {
            let id = UIApplication.shared.beginBackgroundTask(withName: name) {
                // Documented to run on the main thread; the driver ends the task inside `onExpiry`.
                MainActor.assumeIsolated { onExpiry() }
            }
            return id == .invalid ? nil : id.rawValue
        }

        func end(_ token: Int) {
            UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token))
        }
    }
#else
    @MainActor
    final class ActivityKitEffects: TurnActivityEffects {
        var appIsActive: Bool {
            true
        }

        var activitiesEnabled: Bool {
            false
        }

        func endStaleCards() async {}
        func start(_: TurnActivityState) {}
        func update(_: TurnActivityState) async {}
        func end(final _: TurnActivityState?, dismissal _: TurnActivityPolicy.Dismissal) async {}
    }

    @MainActor
    final class UIKitBackgroundTasks: BackgroundTaskHosting {
        func begin(name _: String, onExpiry _: @escaping @MainActor () -> Void) -> Int? {
            nil
        }

        func end(_: Int) {}
    }
#endif
