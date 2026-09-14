//
//  AFMPrefixPrewarm.swift
//  M1K3Inference
//
//  The pure half of Mini's prompt-prefix prewarm (2026-09-14): the switch and
//  the per-turn classification. The prewarm itself is a closed-SDK call
//  (`LanguageModelSession.prewarm(promptPrefix:)`) in the provider.
//
//  On by default. `-afm.prefixPrewarm NO` at launch (or `defaults write`) turns
//  it off — the A/B arm its timing was measured against, and the way back if a
//  future OS makes the prefix cost more than it saves. Read through ONE reader:
//  a launch argument arrives as a string, and `object(forKey:) as? Bool` reads
//  "NO" as nil (the #324 consent bug).
//
//  Signed: Kev + claude-opus-5, 2026-09-14, Confidence 0.9 (pure, pinned by
//  AFMPrefixPrewarmTests). Prior: Unknown
//

import Foundation

public enum AFMPrefixPrewarm {
    public static let defaultsKey = "afm.prefixPrewarm"

    /// Absent means on; a stored Bool or a launch-argument string reads the way
    /// its words say ("NO", "false", "0" off; "YES", "1" on).
    public static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: defaultsKey) == nil || defaults.bool(forKey: defaultsKey)
    }

    /// Whether a prewarmed session may serve this prompt. One warmed on a prefix
    /// serves only a prompt that begins with it: any other call — the
    /// conversation titler, a synthesis — runs on a fresh session and leaves the
    /// warm one for the turn it was built for. Warm on the instructions alone,
    /// any call may have it (as before).
    public static func accepts(prefix: String?, prompt: String) -> Bool {
        guard let prefix, !prefix.isEmpty else { return true }
        return prompt.hasPrefix(prefix)
    }

    /// How warm a call's session was, for the `afm turn` log line.
    public enum Warmth: String, Sendable, Equatable {
        /// No prewarmed session was waiting.
        case cold
        /// Prewarmed on the instructions alone.
        case instructions
        /// Prewarmed on a prefix this prompt begins with.
        case prefixHit = "prefix-hit"
        /// A prefix-warm session was waiting for a different prompt; this call
        /// ran on a fresh session and left it there.
        case held

        /// The warmth of a session this call took.
        public static func taken(prefix: String?) -> Warmth {
            prefix?.isEmpty == false ? .prefixHit : .instructions
        }
    }
}
