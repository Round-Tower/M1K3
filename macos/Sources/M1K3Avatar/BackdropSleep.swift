//
//  BackdropSleep.swift
//  M1K3Avatar
//
//  When the chat backdrop may sleep: leave the view tree, so its RealityView (or the pixel
//  face's timeline) stops costing anything. Measured 2026-10-21 on Kev's M1 Max with the chat
//  window in front: the backdrop animating held M1K3 at 46.5% CPU, paused 42.0%, absent 0.0%.
//  RealityKit's frame-rate SPI (`ARView.__preferredFrameRate`) capped at 1 fps changed
//  nothing, and the pixel face cost what the Fox did. Only absence is cheap (the same fact
//  `AvatarPresence` encodes for hidden windows), so an idle backdrop leaves and comes back
//  on any input or the moment M1K3 does anything. Kev's 1.2.0, idle for three hours in
//  front, sat at ~53%.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-21
//  Context: the frame-cap and paused arms were measured and lost; the 90 s window is a
//  judgement (long enough to read an answer, short enough to matter over an afternoon).
//  Confidence: 0.8 — the rule is pinned in BackdropSleepTests; the felt fade is verify-by-launch.
//  Format: MurphySig v0.4 (https://murphysig.dev/spec). Prior: none (new file).
//

import Foundation

public enum BackdropSleep {
    /// Seconds without input before an idle backdrop sleeps.
    public static let idleAfter: TimeInterval = 90

    /// Asleep when M1K3 is doing nothing, the composer is empty, and nobody has touched
    /// the app for `idleAfter`. Any active state (listening, thinking, generating,
    /// speaking) keeps it awake however long the user has been still.
    public static func isAsleep(
        activity: AvatarActivity,
        isTyping: Bool,
        lastInput: Date,
        now: Date,
        idleAfter: TimeInterval = idleAfter
    ) -> Bool {
        guard !activity.isActive, !isTyping else { return false }
        return now.timeIntervalSince(lastInput) >= idleAfter
    }

    /// When to look again: the moment the idle window closes, or now if it already has.
    public static func nextCheck(lastInput: Date, now: Date, idleAfter: TimeInterval = idleAfter) -> Date {
        max(lastInput.addingTimeInterval(idleAfter), now)
    }
}
