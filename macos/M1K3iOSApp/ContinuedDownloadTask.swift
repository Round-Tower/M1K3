//
//  ContinuedDownloadTask.swift
//  M1K3iOS
//
//  The system's continued-processing task (iOS 26, BGContinuedProcessingTask) around a user-started brain
//  download: iOS keeps the download running when the person leaves M1K3 and shows its progress itself, on the
//  Lock Screen and in the Dynamic Island (Kev, 2026-10-12: Apple's UI). Before this, a foreground download died
//  when the phone locked and restarted the file from zero ("Lil Waking seems to hang at 0%"). Network and CPU
//  only: the weights LOAD in the foreground (`ContinuedDownload.loadsNow`), because MLX traps on background Metal.
//  The pure half (identifier, words, units, the foreground rules) is `ContinuedDownload` in M1K3Inference.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-12, Confidence 0.65 (the SDK's rules are followed to the letter; the
//  background run, the system UI and cancelling from it are verify-on-device). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-15 (pre-push review fold) — `onCarry`: whether iOS is carrying the download
//  follows the task (true at attach, false at an expiry), not the submission. A foreground expiry used to leave the
//  app saying it was carried, so the screen could sleep and the transfer restarted. Confidence 0.65.
//  Review: Kev + claude-opus-5.5, 2026-10-15 (pre-push review fold) — `finish` before the system attached withdraws
//  the pending request (`BGTaskScheduler.cancel(taskRequestWithIdentifier:)`). Confidence 0.65 (device-only).
//

#if os(iOS)
    import BackgroundTasks
    import M1K3Inference
    import M1K3LogCore
    import UIKit

    @MainActor
    final class ContinuedDownloadTask {
        /// The SDK kills the app on a second registration of the same identifier: one registration per brain, per
        /// process. The handler routes to `current`, the download in flight.
        private static var registered: Set<String> = []
        private weak static var current: ContinuedDownloadTask?
        private static let log = M1K3Log.logger(.iosCore)

        /// The submitted request's identifier, to withdraw it if the download ends before the system starts it.
        private let identifier: String
        private var task: BGContinuedProcessingTask?
        private var lastFraction: Double = 0
        private let onCarry: @MainActor (Bool) -> Void
        private let onStop: @MainActor () -> Void

        private init(
            identifier: String,
            onCarry: @escaping @MainActor (Bool) -> Void,
            onStop: @escaping @MainActor () -> Void
        ) {
            self.identifier = identifier
            self.onCarry = onCarry
            self.onStop = onStop
        }

        /// Ask iOS to carry the download. nil when it won't (identifier not permitted, submission refused, or the
        /// system busy: `.fail` rather than queue, because a queued task would start after the download it was for):
        /// the download then runs as an ordinary foreground one. `onCarry` says whether iOS is carrying it right now:
        /// true once the system starts the task, false when an expiry lets it go. `onStop` runs when an expiry in
        /// the background ends it, such as the person cancelling it from the system UI.
        static func begin(
            _ plan: ContinuedDownload,
            onCarry: @escaping @MainActor (Bool) -> Void,
            onStop: @escaping @MainActor () -> Void
        ) -> ContinuedDownloadTask? {
            if !registered.contains(plan.identifier) {
                let accepted = BGTaskScheduler.shared.register(forTaskWithIdentifier: plan.identifier, using: .main) { task in
                    MainActor.assumeIsolated {
                        guard let task = task as? BGContinuedProcessingTask, let current else {
                            task.setTaskCompleted(success: false)
                            return
                        }
                        current.attach(task)
                    }
                }
                guard accepted else {
                    log.error("continued download: \(plan.identifier, privacy: .public) is not a permitted identifier")
                    return nil
                }
                registered.insert(plan.identifier)
            }
            let download = ContinuedDownloadTask(identifier: plan.identifier, onCarry: onCarry, onStop: onStop)
            current = download // before submit: the system may start the task at once
            let request = BGContinuedProcessingTaskRequest(
                identifier: plan.identifier, title: plan.title, subtitle: plan.subtitle
            )
            request.strategy = .fail
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                current = nil
                log.notice("continued download: not carried (\(error.localizedDescription, privacy: .public)); foreground only")
                return nil
            }
            log.notice("continued download: \(plan.identifier, privacy: .public) submitted")
            return download
        }

        func report(_ fraction: Double) {
            lastFraction = fraction
            task?.progress.completedUnitCount = ContinuedDownload.completedUnits(fraction: fraction)
        }

        func finish(success: Bool) {
            if task == nil {
                // A fast download can end before the system starts the task: withdraw the request, or it stays
                // pending and the system may show progress for a download that's already done.
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            }
            task?.setTaskCompleted(success: success)
            task = nil
            if Self.current === self { Self.current = nil }
        }

        private func attach(_ task: BGContinuedProcessingTask) {
            self.task = task
            task.progress.totalUnitCount = ContinuedDownload.totalUnits
            task.progress.completedUnitCount = ContinuedDownload.completedUnits(fraction: lastFraction)
            task.expirationHandler = { [weak self] in
                Task { @MainActor in self?.expired() }
            }
            Self.log.notice("continued download: running")
            onCarry(true) // only now may the screen sleep and the row say the person can leave
        }

        private func expired() {
            let active = UIApplication.shared.applicationState == .active
            Self.log.notice("continued download: expired (app active: \(active, privacy: .public))")
            task?.setTaskCompleted(success: false)
            task = nil
            if Self.current === self { Self.current = nil }
            // In the foreground the download carries on as an ordinary one: keep the screen awake again.
            onCarry(false)
            if ContinuedDownload.expiryStopsDownload(appIsActive: active) { onStop() }
        }
    }
#endif
