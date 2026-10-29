//
//  AppEnvironment+Snag.swift
//  M1K3
//
//  #750, the Mac half: the last session didn't close cleanly. M1K3App's delegate owns the
//  `SessionGuard` (marked on the UI launch path, cleared on a clean quit) and hands a standing
//  mark here once the environment exists. A snag always holds the rating ask for three days
//  (`ReviewPromptLedger.recordCrash`), whatever the age band; the one-time offer to send Round
//  Tower a short report (`snag`, ContentView's SnagBanner) is shown only to the bands #708's
//  offer is shown to. The note lives for this session only: the guard has already consumed the
//  mark, so "Not now", or ignoring it, means it never comes back.
//
//  App glue, committed with TDD_SKIP for the view half: the rule is SessionGuard's and
//  SnagReport's, unit-pinned in M1K3Diagnostics; SnagNoteScanTests pins this wiring.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-29, Confidence 0.75 (verify-by-launch owed: a kill -9
//  then a relaunch shows the banner; a ⌘Q then a relaunch does not). Prior: none (new file).
//

import Foundation
import M1K3Diagnostics
import M1K3LogCore
import M1K3Screengrab

extension AppEnvironment {
    /// The guard reads and writes nothing under the screengrab harness (a plate never shows the
    /// note) or in a Debug build, which shares the live defaults: Xcode's Stop is not a snag, and
    /// a Debug run must not consume a Release session's mark. `-armSessionGuard YES` arms a Debug
    /// build for a local verify.
    nonisolated static var sessionGuardInert: Bool {
        if ScreengrabHarness.current.isActive { return true }
        #if DEBUG
            return !UserDefaults.standard.bool(forKey: "armSessionGuard")
        #else
            return false
        #endif
    }

    /// The previous session began at `openedAt` and never closed: hold the rating ask, and raise
    /// the offer for the chat surface (ContentView decides whether this band may see it).
    func noteUncleanExit(openedAt: Date, now: Date = Date()) {
        reviewLedger.recordCrash(at: now)
        snag = SnagNote(openedAt: openedAt, noticedAt: now)
        M1K3Log.logger(.launch)
            .notice("session: the last one didn't close cleanly (began \(openedAt, privacy: .public))")
    }
}
