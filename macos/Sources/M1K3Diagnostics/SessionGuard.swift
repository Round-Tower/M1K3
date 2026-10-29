//
//  SessionGuard.swift
//  M1K3Diagnostics
//
//  Did the last session close cleanly? (#750) The trigger for "I hit a snag last time" and for
//  the rating ask's crash quiet window. MetricKit delivered nothing on Kev's Mac in eight days of
//  logs (2026-10-29, the challenger's check), so the trigger is M1K3's own mark: set when a
//  session begins, cleared when it ends cleanly. The shells say what "clean" is: a normal quit on
//  the Mac (applicationShouldTerminate), a trip to the background on iPhone and iPad (the system
//  may then end the app without a crash). A mark still set at the next launch means the session
//  ended in a crash, an out-of-memory kill or a force-quit, or, on a Mac, a power cut, a kernel
//  panic or a held-power-button reboot. Kev ruled this the trigger ("Didn't close cleanly"),
//  knowing it counts a force-quit, which is usually a hang given up on. If power-loss false
//  positives show up after the freeze, store kern.boottime beside the mark.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-29, Confidence 0.8 (pure, every path pinned in
//  SessionGuardTests; the shells' clean-exit wiring is verify-by-launch). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-29 (pre-push review fold) — end() before the first begin() keeps the
//  mark, and a mark dated after now is reported as now. Confidence 0.8.
//

import Foundation

/// What the guard needs from its store. `UserDefaults` conforms unchanged.
public protocol SessionMarkStorage: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: SessionMarkStorage {}

@MainActor
public final class SessionGuard {
    public static let openKey = "session.openSince"

    private let storage: SessionMarkStorage
    private let inert: Bool
    private let now: () -> Date
    private var begun = false

    /// `inert` reads and writes nothing: the screengrab harness, and Debug builds unless asked
    /// (a Debug run shares the live defaults, and Xcode's Stop is not a snag).
    public init(storage: SessionMarkStorage, inert: Bool, now: @escaping () -> Date = { Date() }) {
        self.storage = storage
        self.inert = inert
        self.now = now
    }

    /// Mark this session open. The FIRST call in a process returns when the previous session began
    /// if it never closed (nil otherwise), so each snag is reported once, by the launch after it.
    /// Later calls (the app back in front) only mark open.
    public func begin() -> Date? {
        guard !inert else { return nil }
        defer { storage.set(now().timeIntervalSince1970, forKey: Self.openKey) }
        guard !begun else { return nil }
        begun = true
        // A clock that ran ahead must not date the report after its own notice.
        return (storage.object(forKey: Self.openKey) as? Double).map { min(Date(timeIntervalSince1970: $0), now()) }
    }

    /// The session ended cleanly, or reached a state the system may end without a crash. Before this
    /// process's first begin it does nothing: a standing mark belongs to that begin (a self-test run
    /// quits without ever beginning, and must not erase a real snag).
    public func end() {
        guard !inert, begun else { return }
        storage.set(nil, forKey: Self.openKey)
    }
}
