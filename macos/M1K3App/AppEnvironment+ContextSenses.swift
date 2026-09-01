//
//  AppEnvironment+ContextSenses.swift
//  M1K3App
//
//  The context senses' app half (docs/CONTEXT_TOOLS_PLAN.md, Phase 1+2):
//  consent keys (default OFF, every one — charter rule 1), the hook that
//  carries the OS providers into the interactive palette only (the
//  ScriptExecutionHook precedent — ask_m1k3/menu-bar/deep-dive structurally
//  never see it), the EventKit + CoreLocation adapters (thin,
//  verify-by-launch), and the TCC probes the Privacy pane's auto-revert
//  reads. Toggle-first, TCC-second per charter rule 4: the OS prompt can
//  only ever fire on first tool use, after the in-app toggle is on — and
//  the warm variant uses inert providers so a launch warm can never
//  trigger a permission dialog.
//
//  Signed: Kev + claude-sonnet-5, 2026-09-01, Confidence 0.8 (keys +
//  gating mirror the hands; the adapters compile + are exercised only by
//  launch — the TCC dance, the one-shot fix and its 15s watchdog are all
//  named ⌘R verify-owed). Prior: none (new file).
//

import CoreLocation
import EventKit
import Foundation
import M1K3AgentTools

extension AppEnvironment {
    /// The context senses (context-tools charter): each default-OFF; off
    /// means the model never sees the tool. battery is exclusion-exempt;
    /// calendar/location are .localSensitive + distillation-tainted.
    nonisolated static let contextBatteryEnabledKey = "contextTools.battery"
    nonisolated static let contextCalendarEnabledKey = "contextTools.calendar"
    nonisolated static let contextLocationEnabledKey = "contextTools.location"
    /// Kev's 2026-09-01 ruling: coarse by default, precise is its own opt-up.
    nonisolated static let contextLocationPreciseKey = "contextTools.locationPrecise"
}

/// Carries the sense providers into `interactiveAgentTools` — non-nil only
/// from the main responder and its warm, so the senses can never reach the
/// MCP/menu-bar/deep-dive palettes (P2, structurally).
struct ContextSenseHook {
    let calendar: any CalendarPeeking
    let location: any LocationProviding

    /// Live OS adapters, for the chat responder only.
    static var live: ContextSenseHook {
        ContextSenseHook(calendar: EventKitCalendarProvider(), location: CoreLocationProvider())
    }

    /// For the persona-prefix warm: the SAME palette (only tool definitions
    /// render into the prefix), providers that can never fire a TCC prompt.
    static var forWarm: ContextSenseHook {
        ContextSenseHook(calendar: NullCalendarPeeking(), location: NullLocationProviding())
    }
}

/// TCC status probes for the Privacy pane's auto-revert (charter fold:
/// a denied grant flips the toggle back with calm copy — never a per-turn
/// "permission denied" loop). Reading status never prompts.
@MainActor
enum ContextSenseAuth {
    static var calendarDenied: Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        // writeOnly can't read events — for this tool that's a denial.
        case .denied, .restricted, .writeOnly: true
        default: false
        }
    }

    static var locationDenied: Bool {
        switch CLLocationManager().authorizationStatus {
        case .denied, .restricted: true
        default: false
        }
    }
}

/// EventKit adapter. The store is created per call (EKEventStore isn't
/// Sendable); a not-yet-determined status requests full access here — first
/// use, after the toggle, per charter rule 4.
struct EventKitCalendarProvider: CalendarPeeking {
    func events(from start: Date, to end: Date) async throws -> [CalendarEventSnapshot] {
        let store = EKEventStore()
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined:
            guard (try? await store.requestFullAccessToEvents()) == true else {
                throw Self.denied
            }
        case .fullAccess:
            break
        default:
            throw Self.denied
        }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map { event in
            CalendarEventSnapshot(
                title: event.title ?? "Untitled",
                start: event.startDate,
                end: event.endDate,
                isAllDay: event.isAllDay
            )
        }
    }

    private static var denied: ContextSenseUnavailable {
        ContextSenseUnavailable(message: "Calendar access is off for M1K3 in macOS "
            + "System Settings (Privacy & Security → Calendars).")
    }
}

/// CoreLocation adapter: a one-shot fix per call, never a stream (charter
/// rule 2). Accuracy is requested to match the precision toggle — coarse
/// asks the OS for kilometre-grade only (data minimisation at the source;
/// the grid-cell rounding in CurrentLocationTool is the output boundary).
struct CoreLocationProvider: LocationProviding {
    func currentLocation() async throws -> LocationSnapshot {
        let precise = UserDefaults.standard.bool(forKey: AppEnvironment.contextLocationPreciseKey)
        let oneShot = await MainActor.run { OneShotLocation(precise: precise) }
        return try await oneShot.fix()
    }
}

/// The delegate dance for a single fix. MainActor: the manager is created
/// on the main run loop and delivers there; delegate callbacks re-assert it.
@MainActor
private final class OneShotLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<LocationSnapshot, Error>?

    init(precise: Bool) {
        super.init()
        manager.desiredAccuracy = precise
            ? kCLLocationAccuracyHundredMeters
            : kCLLocationAccuracyKilometer
        manager.delegate = self
    }

    func fix() async throws -> LocationSnapshot {
        let status = manager.authorizationStatus
        if status == .denied || status == .restricted { throw Self.denied }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            if status == .notDetermined {
                // First use: the TCC prompt. The authorization callback
                // below carries on (or fails calmly) once the user decides.
                manager.requestWhenInUseAuthorization()
            } else {
                manager.requestLocation()
            }
            // A fix that never arrives must not hang the agent turn.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                self?.finish(.failure(ContextSenseUnavailable(
                    message: "Location took too long to resolve — try again."
                )))
            }
        }
    }

    private func finish(_ result: Result<LocationSnapshot, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    nonisolated func locationManagerDidChangeAuthorization(_: CLLocationManager) {
        // The stored manager, not the delegate parameter — a nonisolated
        // parameter can't cross into the assumeIsolated closure (Swift 6).
        MainActor.assumeIsolated {
            switch manager.authorizationStatus {
            case .denied, .restricted:
                finish(.failure(Self.denied))
            case .notDetermined:
                break // The prompt is still up.
            default:
                manager.requestLocation()
            }
        }
    }

    nonisolated func locationManager(_: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            guard let fix = locations.last else { return }
            finish(.success(LocationSnapshot(
                latitude: fix.coordinate.latitude,
                longitude: fix.coordinate.longitude
            )))
        }
    }

    nonisolated func locationManager(_: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            finish(.failure(error))
        }
    }

    private static var denied: ContextSenseUnavailable {
        ContextSenseUnavailable(message: "Location access is off for M1K3 in macOS "
            + "System Settings (Privacy & Security → Location Services).")
    }
}
