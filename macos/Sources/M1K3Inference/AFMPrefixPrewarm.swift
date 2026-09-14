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

    /// How warm a turn's session was, for the `afm turn` log line — the only
    /// place a live trace can say whether the warmed prefix was the one sent.
    public enum Warmth: String, Sendable, Equatable {
        /// No prewarmed session was waiting.
        case cold
        /// Prewarmed on the instructions alone.
        case instructions
        /// Prewarmed on a prefix this prompt begins with.
        case prefixHit = "prefix-hit"
        /// Prewarmed on a prefix this prompt does NOT begin with — the
        /// instructions were still warm; the prefix work was wasted.
        case prefixMiss = "prefix-miss"

        public static func of(prewarmed: Bool, prefix: String?, prompt: String) -> Warmth {
            guard prewarmed else { return .cold }
            guard let prefix, !prefix.isEmpty else { return .instructions }
            return prompt.hasPrefix(prefix) ? .prefixHit : .prefixMiss
        }
    }
}
