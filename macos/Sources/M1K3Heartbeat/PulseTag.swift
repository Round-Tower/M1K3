//
//  PulseTag.swift
//  M1K3Heartbeat
//
//  Structural pulse tags (2026-08-30 addendum, Kev's ruling: "structural
//  only"). A tag describes the SHAPE of a window, never its content — and
//  here the rule binds harder than in the digest, because a tag is a
//  persistent, filterable index, and an index over conversation or memory
//  titles is precisely the "history of what you talked about" the
//  OFF-by-default stance exists to avoid. Topic tags were considered and
//  declined.
//
//  The vocabulary is CLOSED and versioned like the noun list. Explicitly
//  not tags: conversation titles · memory titles or keywords · fun-fact
//  source titles · tool arguments · any exact count. Counts are banded,
//  never exact — a tag carrying "17" is a durable data point about
//  somebody's week.
//
//  The one open-ended member is `agent:<client>` — the MCP client's
//  self-reported name (Claude, Cursor). Client identity is not user
//  content, and the timeline's visit headers already show it.
//
//  Signed: Kev + claude-fable-5, 2026-08-30, Confidence 0.9 (pure value
//  type; vocabulary + normalisation + labels pinned red-first).
//  Prior: none (new file).
//
//  Review: Kev + claude-fable-5.1, 2026-09-07, Confidence 0.85 — Todos v1: three todo:* tags (open / overdue /
//  proposed) with labels.
//  Review: claude-opus-5-5, 2026-11-19 — localisation Phase 0: the filter-chip labels resolve from M1K3Heartbeat's
//  catalog (`bundle: .module`); the brain names (Big, Lil, Mini) and the raw-value fallback stay as they are. English
//  unchanged.

import Foundation

public struct PulseTag: RawRepresentable, Hashable, Sendable, Comparable {
    public let rawValue: String

    /// Public for DB rehydration and forward compatibility (a future
    /// vocabulary version must read back cleanly). Everything the app MINTS
    /// goes through the static members below or `agentClient(_:)` —
    /// `HeartbeatComposer.tags(from:renderedBy:)` is the only producer.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func < (lhs: PulseTag, rhs: PulseTag) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    // MARK: - The closed vocabulary

    public static let firstToday = PulseTag(rawValue: "pulse:first-today")
    public static let quiet = PulseTag(rawValue: "pulse:quiet")
    public static let active = PulseTag(rawValue: "pulse:active")

    public static let machineCool = PulseTag(rawValue: "machine:cool")
    public static let machineWarm = PulseTag(rawValue: "machine:warm")
    public static let machineHot = PulseTag(rawValue: "machine:hot")
    public static let lowPower = PulseTag(rawValue: "machine:low-power")

    public static let charging = PulseTag(rawValue: "power:charging")
    public static let onBattery = PulseTag(rawValue: "power:battery")

    public static let memoryLearned = PulseTag(rawValue: "memory:learned")
    public static let memoryCorrected = PulseTag(rawValue: "memory:corrected")

    public static let chatTouched = PulseTag(rawValue: "chat:touched")

    public static let agentVisited = PulseTag(rawValue: "agent:visited")

    public static let brainBig = PulseTag(rawValue: "brain:big")
    public static let brainLil = PulseTag(rawValue: "brain:lil")
    public static let brainMini = PulseTag(rawValue: "brain:mini")
    public static let toldByDigest = PulseTag(rawValue: "told-by:digest")

    /// The todo list (2026-09-07): open items existed at pulse time, at
    /// least one was overdue, and — the resident's one write — this pulse's
    /// narrative PROPOSED a todo (pending until the user accepts).
    public static let todosOpen = PulseTag(rawValue: "todo:open")
    public static let todoOverdue = PulseTag(rawValue: "todo:overdue")
    public static let todoProposed = PulseTag(rawValue: "todo:proposed")

    /// The MCP client's self-reported name, normalised to a slug: lowercase,
    /// whitespace to dashes, everything but letters/digits/dashes dropped.
    public static func agentClient(_ name: String) -> PulseTag {
        let slug = name.lowercased()
            .map { character -> Character in character.isWhitespace ? "-" : character }
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return PulseTag(rawValue: "agent:\(String(slug))")
    }

    // MARK: - Display

    /// Short human copy for the filter chips. Unknown raw values (a future
    /// vocabulary read by an older build) fall back to the value half.
    public var displayLabel: String {
        switch self {
        case .firstToday: return String(localized: "First today", bundle: .module)
        case .quiet: return String(localized: "Quiet", bundle: .module)
        case .active: return String(localized: "Active", bundle: .module)
        case .machineCool: return String(localized: "Ran cool", bundle: .module)
        case .machineWarm: return String(localized: "Ran warm", bundle: .module)
        case .machineHot: return String(localized: "Ran hot", bundle: .module)
        case .lowPower: return String(localized: "Low power", bundle: .module)
        case .charging: return String(localized: "Charging", bundle: .module)
        case .onBattery: return String(localized: "On battery", bundle: .module)
        case .memoryLearned: return String(localized: "Learned", bundle: .module)
        case .memoryCorrected: return String(localized: "Corrected", bundle: .module)
        case .chatTouched: return String(localized: "We talked", bundle: .module)
        case .agentVisited: return String(localized: "Agent visit", bundle: .module)
        case .brainBig: return "Big"
        case .brainLil: return "Lil"
        case .brainMini: return "Mini"
        case .toldByDigest: return String(localized: "Digest-told", bundle: .module)
        case .todosOpen: return String(localized: "Todos open", bundle: .module)
        case .todoOverdue: return String(localized: "Overdue", bundle: .module)
        case .todoProposed: return String(localized: "Suggested", bundle: .module)
        default:
            let value = rawValue.split(separator: ":").dropFirst().joined(separator: ":")
            guard !value.isEmpty else { return rawValue }
            if rawValue.hasPrefix("agent:") {
                return value.split(separator: "-").map(\.capitalized).joined(separator: " ")
            }
            return String(value)
        }
    }
}
