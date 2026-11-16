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
//  Review: Kev + claude-opus-5.5, 2026-11-16 — `UserNoticeNotifier` + `TurnNoticeDelegate`: the phone's "your
//  answer is ready" notification (decisions in TurnNoticePolicy); a tap opens the chat via m1k3://chat.

import Foundation
import M1K3Chat
import M1K3LiveActivity
import M1K3LogCore
import M1K3Screengrab
#if os(iOS)
    import ActivityKit
    import UIKit
    import UserNotifications
#endif

extension TurnActivityDriver {
    static func live() -> TurnActivityDriver {
        // The notification delegate is NOT installed here: the core is built asynchronously, and a cold-launch tap
        // on a notice must reach a delegate (`M1K3iOSApp.init`).
        TurnActivityDriver(effects: ActivityKitEffects(), tasks: UIKitBackgroundTasks(), notifier: UserNoticeNotifier())
    }
}

#if os(iOS)
    @MainActor
    final class ActivityKitEffects: TurnActivityEffects {
        private static let log = M1K3Log.logger(.iosCore)

        var appIsActive: Bool {
            UIApplication.shared.applicationState == .active
        }

        /// `.inactive` (a Control Center pull, a system sheet, the app switcher) is still in front.
        var appIsInForeground: Bool {
            UIApplication.shared.applicationState != .background
        }

        private var saidDisabled = false

        var activitiesEnabled: Bool {
            let enabled = ActivityAuthorizationInfo().areActivitiesEnabled
            // Said once per launch: with Live Activities off a long turn shows no card, and the log says why.
            if !enabled, !saidDisabled {
                saidDisabled = true
                Self.log.notice("live activity: switched off for M1K3 (Settings), no card")
            }
            return enabled
        }

        func endStaleCards() async {
            await Self.endAll(nil, .immediate)
        }

        func start(_ state: TurnActivityState) {
            do {
                let card = try Activity.request(
                    attributes: TurnActivityAttributes(),
                    content: ActivityContent(state: state, staleDate: nil),
                    pushType: nil
                )
                // A breadcrumb per card: the phone's first try showed nothing and the log could not say why.
                Self.log.notice(
                    "live activity started: \(String(describing: state.phase), privacy: .public) · \(card.activityState == .active ? "active" : "not active", privacy: .public) · cards=\(Activity<TurnActivityAttributes>.activities.count, privacy: .public)"
                )
            } catch {
                // Refused (the person switched it off, too many cards): the turn goes on without one.
                Self.log.notice("live activity: refused: \(String(describing: error), privacy: .public)")
            }
        }

        func update(_ state: TurnActivityState) async {
            Self.log.notice("live activity update: \(String(describing: state.phase), privacy: .public)")
            await Self.updateAll(ActivityContent(state: state, staleDate: nil))
        }

        func end(final: TurnActivityState?, dismissal: TurnActivityPolicy.Dismissal) async {
            Self.log.notice(
                "live activity end: \(final.map { String(describing: $0.phase) } ?? "none", privacy: .public) · \(String(describing: dismissal), privacy: .public)"
            )
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

    /// The phone's "your answer is ready" notification (the decisions are `TurnNoticePolicy`). Generic words only;
    /// nothing posts unless the person allowed it, and no badge is ever set.
    @MainActor
    final class UserNoticeNotifier: TurnNotifying {
        private let center = UNUserNotificationCenter.current()

        func post(_ notice: TurnNoticePolicy.Notice) async {
            // A banner over the app is in the frame: nothing posts under the screengrab harness.
            guard !ScreengrabHarness.current.isActive else { return }
            let status = await center.notificationSettings().authorizationStatus
            guard status == .authorized || status == .provisional || status == .ephemeral else { return }
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.body
            content.threadIdentifier = TurnNoticePolicy.threadIdentifier
            content.sound = .default
            content.interruptionLevel = .active
            // The same identifier every time: a later notice replaces the earlier instead of stacking.
            let request = UNNotificationRequest(identifier: TurnNoticePolicy.identifier, content: content, trigger: nil)
            try? await center.add(request)
        }

        func requestPermissionIfUndecided() async {
            // A long answer in a screengrab or UI-test run must never raise the system prompt.
            guard !ScreengrabHarness.current.isActive else { return }
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }

        func clearDelivered() async {
            center.removeDeliveredNotifications(withIdentifiers: [TurnNoticePolicy.identifier])
            center.removePendingNotificationRequests(withIdentifiers: [TurnNoticePolicy.identifier])
        }
    }

    /// A tap on the notice opens the chat through the same `m1k3://chat` link the Live Activity uses. A turn
    /// notice never presents over the app (none is posted while it is in front); any other notification keeps
    /// the system default, so a future feature is not silently muted by this delegate.
    final class TurnNoticeDelegate: NSObject, UNUserNotificationCenterDelegate {
        @MainActor private static let shared = TurnNoticeDelegate()

        @MainActor static func install() {
            UNUserNotificationCenter.current().delegate = shared
        }

        func userNotificationCenter(
            _: UNUserNotificationCenter, willPresent notification: UNNotification
        ) async -> UNNotificationPresentationOptions {
            notification.request.identifier == TurnNoticePolicy.identifier ? [] : [.banner, .sound, .list]
        }

        func userNotificationCenter(
            _: UNUserNotificationCenter, didReceive response: UNNotificationResponse
        ) async {
            guard response.notification.request.identifier == TurnNoticePolicy.identifier else { return }
            await MainActor.run {
                UIApplication.shared.open(TurnActivityLink.url, options: [:], completionHandler: nil)
            }
        }
    }
#else
    @MainActor
    final class UserNoticeNotifier: TurnNotifying {
        func post(_: TurnNoticePolicy.Notice) async {}
        func requestPermissionIfUndecided() async {}
        func clearDelivered() async {}
    }

    enum TurnNoticeDelegate {
        @MainActor static func install() {}
    }

    @MainActor
    final class ActivityKitEffects: TurnActivityEffects {
        var appIsActive: Bool {
            true
        }

        var appIsInForeground: Bool {
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
