//
//  ChatEgressConsent.swift
//  M1K3LanguageModel
//
//  Phase 17a — the dedicated chat-egress consent (the wall before the door).
//
//  The EscalationLadder's `networkAllowed` gate was provisionally sourced from
//  the web-search toggle — which defaults ON and governs a DIFFERENT egress
//  category (web tools fetching pages, not chat leaving the device). Sending a
//  conversation to a network model is the one thing M1K3's signed promise says
//  doesn't happen without explicit consent, so it gets its own key with the
//  opposite default: OFF until the user says otherwise, and an absent value is
//  a NO — consent is given, never assumed and never inherited from another
//  setting.
//
//  The consent surface ships WITH the PCC rung (17b, 1.1.0). This key makes
//  the ladder's gate honest.
//
//  Signed: Kev + claude-fable-5, 2026-07-08, Confidence 0.9 (pure, total,
//  test-pinned; the default-OFF semantics are the point — challenger finding
//  on the default-ON proxy folded, PLAN.md Phase 17). Prior: Unknown
//
//  Review: Kev + claude-opus-5, 2026-09-14 — `persisted(in:)`, the one reader
//  of the key: the PCC shell's views (@AppStorage) and its send-time gate
//  (`object as? Bool`) disagreed on a string value and refused a send the UI
//  had offered, silently. The consent surface now ships with the PCC rung, as
//  the header planned. Confidence now 0.9.
//

import Foundation

/// Resolves the ladder's `networkAllowed` gate from the persisted chat-egress
/// consent. Pure and total so the semantics live in the package, not the app
/// target: the composition root reads UserDefaults and passes the raw optional.
public enum ChatEgressConsent {
    /// The UserDefaults key the app persists the consent under. Owned here so
    /// every shell (macOS, iOS/visionOS) spells it identically.
    public static let defaultsKey = "chatEgressAllowed"

    /// `nil` (never asked / never answered) is a NO. Only an explicit true
    /// opens the gate.
    public static func networkAllowed(persisted: Bool?) -> Bool {
        persisted ?? false
    }

    /// The persisted answer, read the way the views' @AppStorage reads it: nil
    /// when the key is absent (never answered), else `bool(forKey:)`, which also
    /// coerces the string a launch argument, `defaults write -string` or a
    /// profile can store. A send-time `as? Bool` read got nil for a string the
    /// view had read as true, and refused a send the UI had offered (seen live
    /// 2026-09-14). One reader for every caller keeps them in step.
    public static func persisted(in defaults: UserDefaults) -> Bool? {
        defaults.object(forKey: defaultsKey) == nil ? nil : defaults.bool(forKey: defaultsKey)
    }
}
