//
//  MemoryRecency.swift
//  M1K3Chat
//
//  Tier 1 of the dream-cycle plan (scratch/dream-cycle/SPEC.md): read-time
//  honesty for the memory block. Each remembered fact carries when it was
//  learned — "(learned 3 days ago)" — so the model resolves contradictions
//  at read time with the signal a human would use, before any destructive
//  write-side machinery exists.
//
//  Deliberately Calendar/locale-free: plain 86 400-second days off a supplied
//  clock, so the phrase is deterministic in tests and identical on every
//  device. The bands trade precision for prompt calm — "9 months ago" reads
//  better to a small model (and a human) than "274 days ago".
//
//  Signed: Kev + claude-fable-5, 2026-07-30, Confidence 0.9 (pure, test-pinned;
//  wording subject to the live-path A/B the spec requires before ship).
//  Prior: Unknown
//

import Foundation

public enum MemoryRecency {
    /// "today" / "yesterday" / "N days ago" / "N weeks ago" / "N months ago" /
    /// "a year ago" / "N years ago". Future timestamps (clock skew) clamp to
    /// "today" — never a negative age.
    public static func phrase(from createdAt: Date, to now: Date) -> String {
        let days = max(0, Int(now.timeIntervalSince(createdAt) / 86400))
        switch days {
        case 0: return "today"
        case 1: return "yesterday"
        case 2 ..< 14: return "\(days) days ago"
        case 14 ..< 61: return "\(days / 7) weeks ago"
        case 61 ..< 365: return "\(days * 12 / 365) months ago"
        case 365 ..< 730: return "a year ago"
        default: return "\(days / 365) years ago"
        }
    }
}
