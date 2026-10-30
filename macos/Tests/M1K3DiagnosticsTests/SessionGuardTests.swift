//
//  SessionGuardTests.swift
//  M1K3DiagnosticsTests
//
//  Did the last session close cleanly? (#750) The trigger for "I hit a snag last time" and for
//  the rating ask's quiet window. MetricKit delivered nothing on Kev's Mac in eight days of
//  logs (2026-10-29), so the trigger is M1K3's own mark instead: set when a session begins,
//  cleared on a clean quit (Mac) or a trip to the background (iPhone). A mark still there at
//  the next launch means that session ended in a crash, an out-of-memory kill or a force-quit.
//  Kev's call: "Didn't close cleanly". Storage is a dictionary here, UserDefaults in the shells.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-29, Confidence 0.8 (pure; what counts as clean on
//  each platform is the shells' to wire and is verify-by-launch). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-29 (pre-push review fold) — an end before the process's first begin
//  keeps the mark (a self-test quit must not erase a real snag), and a mark dated after now is reported as now.
//  Confidence 0.8.
//

import Foundation
@testable import M1K3Diagnostics
import Testing

@MainActor
struct SessionGuardTests {
    private final class MemoryStorage: SessionMarkStorage {
        var values: [String: Any] = [:]
        func object(forKey key: String) -> Any? {
            values[key]
        }

        func set(_ value: Any?, forKey key: String) {
            if let value { values[key] = value } else { values.removeValue(forKey: key) }
        }
    }

    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func guardian(_ storage: MemoryStorage, at: Date, inert: Bool = false) -> SessionGuard {
        SessionGuard(storage: storage, inert: inert, now: { at })
    }

    @Test("a first launch finds nothing, and marks the session open")
    func firstLaunchIsClean() {
        let storage = MemoryStorage()
        #expect(guardian(storage, at: epoch).begin() == nil)
        #expect(storage.object(forKey: SessionGuard.openKey) as? Double == epoch.timeIntervalSince1970)
    }

    @Test("a clean close leaves nothing for the next launch")
    func cleanCloseIsClean() {
        let storage = MemoryStorage()
        let first = guardian(storage, at: epoch)
        _ = first.begin()
        first.end()
        #expect(storage.values.isEmpty)
        #expect(guardian(storage, at: epoch.addingTimeInterval(60)).begin() == nil)
    }

    @Test("a session that never closed is reported once, with the time it began")
    func uncleanSessionIsReportedOnce() {
        let storage = MemoryStorage()
        _ = guardian(storage, at: epoch).begin()
        let next = guardian(storage, at: epoch.addingTimeInterval(3600))
        #expect(next.begin() == epoch)
        next.end()
        #expect(guardian(storage, at: epoch.addingTimeInterval(7200)).begin() == nil)
    }

    @Test("two unclean sessions in a row are each reported by the launch after them")
    func backToBackSnags() {
        let storage = MemoryStorage()
        _ = guardian(storage, at: epoch).begin()
        let second = epoch.addingTimeInterval(3600)
        #expect(guardian(storage, at: second).begin() == epoch)
        #expect(guardian(storage, at: second.addingTimeInterval(3600)).begin() == second)
    }

    @Test("only a process's first begin reads the mark; later ones (back to the front) just mark open")
    func laterBeginsOnlyMark() {
        let storage = MemoryStorage()
        var clock = epoch
        let session = SessionGuard(storage: storage, inert: false, now: { clock })
        #expect(session.begin() == nil)
        session.end()
        clock = epoch.addingTimeInterval(600)
        #expect(session.begin() == nil, "a return from the background is not a new launch")
        #expect(storage.object(forKey: SessionGuard.openKey) as? Double == clock.timeIntervalSince1970)
        clock = epoch.addingTimeInterval(1200)
        #expect(session.begin() == nil, "even with the mark still set, a second begin never reports")
    }

    @Test("inert (screengrab harness, Debug without the argv): reads nothing and writes nothing")
    func inertTouchesNothing() {
        let storage = MemoryStorage()
        storage.set(epoch.timeIntervalSince1970, forKey: SessionGuard.openKey)
        let session = guardian(storage, at: epoch.addingTimeInterval(60), inert: true)
        #expect(session.begin() == nil)
        session.end()
        #expect(storage.object(forKey: SessionGuard.openKey) as? Double == epoch.timeIntervalSince1970,
                "a Release session's mark survives a Debug run")
    }

    @Test("an end before this process's first begin keeps a standing mark for that begin to report")
    func endBeforeBeginKeepsTheMark() {
        let storage = MemoryStorage()
        storage.set(epoch.timeIntervalSince1970, forKey: SessionGuard.openKey)
        let session = guardian(storage, at: epoch.addingTimeInterval(60))
        session.end() // a self-test quit, or a background before the first active
        #expect(session.begin() == epoch)
    }

    @Test("a mark dated after now (a clock that ran ahead) is reported as now, never in the future")
    func futureMarkIsHeldAtNow() {
        let storage = MemoryStorage()
        storage.set(epoch.addingTimeInterval(86400).timeIntervalSince1970, forKey: SessionGuard.openKey)
        #expect(guardian(storage, at: epoch).begin() == epoch)
    }
}
