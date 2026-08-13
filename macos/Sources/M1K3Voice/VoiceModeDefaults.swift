//
//  VoiceModeDefaults.swift
//  M1K3Voice
//
//  The UserDefaults slot that says "a hands-free conversation is happening right
//  now", owned by the package so both shells read the same one.
//
//  It lives here for the reason `EndpointCadence` does: the Mac and iOS shells
//  each grew their own copy of the voice timings from the same complaint and
//  drifted apart (2.0/4.5/30 against 2.0/3.5/20) before anyone noticed. A
//  persisted key is worse to duplicate than a number — two shells with two
//  string literals agree until someone fixes a typo in one of them.
//
//  Why a defaults flag rather than reading the live loop: the readers are
//  `@Sendable` closures on the responder's turn path and cannot touch a
//  main-actor `voiceLoop`. The Mac shell has maintained exactly this key since
//  voice-first shipped (2026-06-11) — the value is unchanged, so nothing
//  migrates; iOS simply stops being the shell that never set it.
//
//  Signed: Kev + claude-opus-5, 2026-08-13, Confidence 0.9 (the literal is
//  pinned by test against the value already on disk in every existing install).
//  Prior: Unknown.
//

import Foundation

public enum VoiceModeDefaults {
    /// True while voice-first mode is active. Never restored across launches —
    /// a stale `true` (crash or force-quit mid-conversation) would silently
    /// apply spoken budgets and forced-fast thinking to every typed turn, so
    /// both shells clear it at launch.
    public static let activeKey = "voiceMode.active"

    /// Clear the flag at launch. Voice mode is never restored across launches,
    /// and a stale `true` — a crash or a jetsam kill mid-conversation — would
    /// apply spoken budgets to every typed turn until the user happened to enter
    /// and leave voice mode again.
    ///
    /// Shared rather than written inline in each shell for the same reason the
    /// key is: two copies of a one-liner about a persisted flag agree right up
    /// until one of them is fixed (review catch, PR #120).
    public static func resetAtLaunch() {
        UserDefaults.standard.set(false, forKey: activeKey)
    }

    /// Live read, from anywhere. Absent key reads as "not in voice mode", which
    /// is the safe direction: a missed spoken turn costs latency, a wrongly
    /// spoken typed turn costs grounding the reader can actually use.
    public static var isActive: Bool {
        UserDefaults.standard.bool(forKey: activeKey)
    }
}
