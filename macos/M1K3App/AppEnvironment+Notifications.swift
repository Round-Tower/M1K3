//
//  AppEnvironment+Notifications.swift
//  M1K3App
//
//  The "your long think is done" local notification: when a turn runs long and
//  you've tabbed away, M1K3 pings you that an answer is ready. Opt-in (default
//  OFF) — the system permission prompt fires only when you flip the Settings
//  toggle, never on launch. Backgrounded-only and threshold-gated by the pure
//  TurnNotificationPolicy (unit-tested in M1K3Chat); this file is the effect.
//
//  Privacy: the notification body is GENERIC — never the answer text. M1K3 is
//  on-device-only, and surfacing a reply on the lock screen / Notification Centre
//  would leak exactly the private content the product exists to keep local.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-14, Confidence 0.8 (policy TDD'd; the
//  UNUserNotificationCenter effect + the permission flow are verify-by-launch).
//  Prior: Unknown

import Foundation
import M1K3Chat
import os
import UserNotifications

private let notifyLog = Logger(subsystem: "app.m1k3", category: "notify")

/// Thin wrapper over UNUserNotificationCenter for the long-think ping. The
/// decision of WHETHER to fire is the pure TurnNotificationPolicy; this is the
/// platform effect, so it's verify-by-launch.
enum TurnNotifier {
    /// Request authorization — called only when the user opts in, so the system
    /// prompt appears on an explicit toggle, never at launch. Returns whether it
    /// was granted (the toggle reflects the real grant).
    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            notifyLog.error("authorization request failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Post the generic "answer ready" notification. No content preview by design
    /// (privacy). The center silently drops it if authorization was never granted.
    static func notifyTurnFinished() async {
        await post(title: "M1K3 has your answer", body: "Your reply is ready.")
    }

    /// A model finished downloading in the background — ready to switch to. The
    /// model NAME is not private (it's a public model id), so it's safe to show,
    /// unlike a turn's content.
    static func notifyDownloadComplete(modelName: String) async {
        await post(title: "Download complete", body: "\(modelName) is downloaded and ready to load.")
    }

    /// A model finished loading and M1K3 can now answer with it.
    static func notifyModelReady(modelName: String) async {
        await post(title: "M1K3 is ready", body: "\(modelName) has finished loading.")
    }

    /// A delegated deep dive landed in the chat. No content preview by design
    /// (privacy — same stance as the turn-finished ping).
    static func notifyDeepDiveFinished() async {
        await post(title: "Deep dive finished", body: "M1K3's background work is ready in the chat.")
    }

    /// A heartbeat pulse landed. DELIBERATE exception to the generic-body rule
    /// (Kev's call, 2026-08-06): the body IS the pulse — a summary M1K3 itself
    /// composed under the digest's privacy rules (titles/counts, never message
    /// text), behind its own opt-in, so the "status update" actually reaches
    /// the lock screen it was made for. macOS preview-hiding still applies.
    static func notifyHeartbeatPulse(text: String) async {
        await post(title: "M1K3's heartbeat", body: text)
    }

    /// Shared post path — generic content, no trigger (immediate). The center
    /// silently drops it if authorization was never granted.
    private static func post(title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            notifyLog.error("could not post notification: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension AppEnvironment {
    /// UserDefaults flag for the long-think notification (default OFF).
    static var notifyOnLongTurnKey: String {
        "notifications.longTurn"
    }

    var notifyOnLongTurnEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.notifyOnLongTurnKey)
    }

    /// The same opt-in also gates the model-lifecycle pings (download complete,
    /// model ready) — one "notify me" switch, one system permission grant. Named
    /// separately so the call sites read honestly rather than "longTurn".
    var notificationsEnabled: Bool {
        notifyOnLongTurnEnabled
    }

    /// Flip the opt-in. Turning it ON requests authorization first and only
    /// persists ON if the user granted it — so a denied prompt leaves the toggle
    /// honestly OFF rather than silently inert.
    func setLongTurnNotifications(_ enabled: Bool) async {
        guard enabled else {
            UserDefaults.standard.set(false, forKey: Self.notifyOnLongTurnKey)
            return
        }
        let granted = await TurnNotifier.requestAuthorization()
        UserDefaults.standard.set(granted, forKey: Self.notifyOnLongTurnKey)
    }

    /// Called at the end of a successful turn: ping only if opted in, backgrounded,
    /// and the turn ran long enough (the pure policy decides). `appActive` is read
    /// by the @MainActor caller and passed in, so this effect never reaches into
    /// global AppKit state — the AppKit/main-actor dependency stays explicit at the
    /// call site rather than hidden inside an async method body.
    func maybeNotifyTurnFinished(duration: Duration, appActive: Bool) async {
        guard TurnNotificationPolicy.shouldNotify(
            turnDuration: duration,
            appActive: appActive,
            enabled: notifyOnLongTurnEnabled
        ) else { return }
        await TurnNotifier.notifyTurnFinished()
    }

    /// Ping when a background model download finishes — only if opted in AND the
    /// app is backgrounded (you don't need a banner if you're watching the bar).
    /// No duration threshold: unlike a turn, "done" is always worth surfacing.
    /// `appActive` is read by the @MainActor caller, same explicit-dependency
    /// stance as `maybeNotifyTurnFinished`.
    func maybeNotifyDownloadComplete(modelName: String, appActive: Bool) async {
        guard notificationsEnabled, !appActive else { return }
        await TurnNotifier.notifyDownloadComplete(modelName: modelName)
    }

    /// Ping when a delegated deep dive delivers — same gate as the model
    /// lifecycle pings (opted in AND backgrounded; the transcript already
    /// carries the result when the user is watching).
    func maybeNotifyDeepDiveFinished(appActive: Bool) async {
        guard notificationsEnabled, !appActive else { return }
        await TurnNotifier.notifyDeepDiveFinished()
    }

    /// Ping when a model finishes loading and is ready to answer — same gate.
    func maybeNotifyModelReady(modelName: String, appActive: Bool) async {
        guard notificationsEnabled, !appActive else { return }
        await TurnNotifier.notifyModelReady(modelName: modelName)
    }

    // MARK: Heartbeat pulse notification (its own opt-in — a 2-hourly rich

    // ping is a different consent than "tell me when my answer is done")

    /// UserDefaults flag for the pulse notification (default OFF).
    static var notifyOnHeartbeatKey: String {
        "notifications.heartbeat"
    }

    var notifyOnHeartbeatEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.notifyOnHeartbeatKey)
    }

    /// Flip the pulse-notification opt-in — same honest-grant contract as
    /// `setLongTurnNotifications` (ON persists only if authorization granted).
    func setHeartbeatNotifications(_ enabled: Bool) async {
        guard enabled else {
            UserDefaults.standard.set(false, forKey: Self.notifyOnHeartbeatKey)
            return
        }
        let granted = await TurnNotifier.requestAuthorization()
        UserDefaults.standard.set(granted, forKey: Self.notifyOnHeartbeatKey)
    }

    /// Ping with the pulse itself — only if opted in AND backgrounded (an open
    /// window or popover already shows it; same explicit `appActive` stance as
    /// every other ping).
    func maybeNotifyHeartbeatPulse(text: String, appActive: Bool) async {
        guard notifyOnHeartbeatEnabled, !appActive else { return }
        await TurnNotifier.notifyHeartbeatPulse(text: text)
    }
}
