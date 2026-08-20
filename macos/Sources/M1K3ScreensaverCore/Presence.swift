//
//  Presence.swift
//  M1K3ScreensaverCore
//
//  What the screensaver SAYS M1K3 is doing — the "what my machine got up to
//  while you were away" line. A pure snapshot + formatter; the `.saver` glue
//  builds the snapshot from whatever it can reach (a loopback MCP `get_status`
//  poll, a read-only `heartbeat.sqlite` peek) and passes it here for the copy.
//
//  Everything the snapshot carries is M1K3's OWN state (its brain, its own
//  heartbeat narrative) — never a visiting agent's content. On a screensaver
//  (you are away; unlikely to land in a work screenshot) the verbatim heartbeat
//  line is acceptable, unlike the always-on desktop surface the challenger pass
//  ruled out.
//
//  Signed: Kev + claude-opus-4-8, 2026-08-20, Confidence 0.85 (pure formatting,
//  TDD'd; the live probe that fills the snapshot is a named follow-up gated on
//  the legacyScreenSaver sandbox permissions). Prior: HeartbeatComposer copy.
//

import Foundation

/// A read of M1K3's presence. All fields optional/false so an unreachable app
/// (port closed, or the sandbox blocks the probe) degrades to a calm resting
/// state rather than an error.
public struct PresenceSnapshot: Sendable, Equatable {
    public var isThinking: Bool
    public var isSpeaking: Bool
    /// The resident brain's display name ("Lil", "Big", "Mini"), if known.
    public var brainName: String?
    /// The latest heartbeat narrative, verbatim (own output).
    public var latestHeartbeat: String?
    /// How long ago that heartbeat pulse landed.
    public var heartbeatAge: TimeInterval?
    /// Whether M1K3 is reachable at all (loopback answered). When false the
    /// surface shows the ambient resting state with no live claims.
    public var reachable: Bool

    public init(
        isThinking: Bool = false,
        isSpeaking: Bool = false,
        brainName: String? = nil,
        latestHeartbeat: String? = nil,
        heartbeatAge: TimeInterval? = nil,
        reachable: Bool = false
    ) {
        self.isThinking = isThinking
        self.isSpeaking = isSpeaking
        self.brainName = brainName
        self.latestHeartbeat = latestHeartbeat
        self.heartbeatAge = heartbeatAge
        self.reachable = reachable
    }

    /// The calm default when nothing is known.
    public static let resting = PresenceSnapshot()
}

public enum PresenceFormatter {
    /// The one-line status: what M1K3 is doing right now.
    public static func statusLine(_ snap: PresenceSnapshot) -> String {
        if snap.isSpeaking { return "M1K3 is speaking" }
        if snap.isThinking {
            if let brain = snap.brainName { return "\(brain) is thinking" }
            return "M1K3 is thinking"
        }
        if !snap.reachable { return "M1K3 rests" }
        return "M1K3 is here, keeping watch"
    }

    /// The heartbeat line + its relative age, or nil if there's no pulse to show.
    public static func heartbeatLine(_ snap: PresenceSnapshot) -> String? {
        guard let pulse = snap.latestHeartbeat?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pulse.isEmpty
        else { return nil }
        if let age = snap.heartbeatAge {
            return "\(relativeAge(age)) — \(pulse)"
        }
        return pulse
    }

    /// A compact, human relative age ("just now", "2h ago", "yesterday").
    public static func relativeAge(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 90 { return "just now" }
        let minutes = Int((s / 60).rounded())
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = Int((s / 3600).rounded())
        if hours < 24 { return "\(hours)h ago" }
        let days = Int((s / 86400).rounded())
        if days == 1 { return "yesterday" }
        return "\(days)d ago"
    }
}
