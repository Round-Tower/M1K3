//
//  NarrativeGuard.swift
//  M1K3Heartbeat
//
//  The confabulation tripwire between the model's narrative and the pulse
//  that gets stored. Heuristic by design: any digit run in the narrative
//  must already appear in the material the prompt showed the model — the
//  digest PLUS the day's earlier pulses (pulse 2's live rejection,
//  2026-08-06 22:32: the model faithfully threaded "4GB" from the morning
//  pulse and the digest-only check called it invented). Plus the Mac-noun
//  tripwire (the first pulse opened "Mac's breathing easy"), emptiness,
//  and length bounds.
//
//  Named limit: digit-free fabrication ("looks like rain") passes — the
//  bound there is the render prompt's add-nothing rule plus the fallback
//  asymmetry: a false REJECT costs style (the digest ships), a false PASS
//  is confined to unnumbered prose.
//
//  Signed: Kev + claude-fable-5, 2026-08-06, Confidence 0.85 (heuristic
//  limits named above; behaviour pinned by tests). Prior: none (new file).
//  Review: Kev + claude-fable-5, 2026-08-06 (late) — earlier-pulse digits
//  admitted after the live pulse-2 rejection; Bool validate now wraps a
//  reason-bearing verdict so the log can say WHY without content.
//

import Foundation

public enum NarrativeGuard {
    /// A narrative longer than this is a runaway generation, not a pulse.
    public static let maxLength = 1600

    /// Content-free rejection reasons — safe to log verbatim.
    public enum Verdict: String, Sendable, Equatable {
        case pass
        case empty
        case tooLong = "too-long"
        case macNoun = "mac-noun"
        case inventedDigit = "invented-digit"
    }

    /// The platform-honesty tripwire. `.simple` word boundaries: the default
    /// Unicode algorithm treats "Mac's" as ONE word, so `\b` never fires
    /// before the apostrophe — the exact shape of the first live miss.
    /// nonisolated(unsafe): this toolchain treats `Regex` as non-Sendable;
    /// a literal with no transform closures is immutable, so unsafe is
    /// sound (the M1K3LogCore.LogPreview precedent).
    private nonisolated(unsafe) static let macNoun = /\bMacs?\b/.wordBoundaryKind(.simple)

    public static func verdict(
        narrative: String,
        digest: String,
        earlierPulses: [String] = [],
        maxLength: Int = NarrativeGuard.maxLength
    ) -> Verdict {
        let trimmed = narrative.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard trimmed.count <= maxLength else { return .tooLong }
        guard trimmed.firstMatch(of: macNoun) == nil else { return .macNoun }
        var allowed = digitRuns(in: digest)
        for pulse in earlierPulses {
            allowed.formUnion(digitRuns(in: pulse))
        }
        guard digitRuns(in: narrative).isSubset(of: allowed) else { return .inventedDigit }
        return .pass
    }

    public static func validate(
        narrative: String,
        digest: String,
        earlierPulses: [String] = [],
        maxLength: Int = NarrativeGuard.maxLength
    ) -> Bool {
        verdict(
            narrative: narrative, digest: digest,
            earlierPulses: earlierPulses, maxLength: maxLength
        ) == .pass
    }

    private static func digitRuns(in text: String) -> Set<String> {
        var runs: Set<String> = []
        var current = ""
        for character in text {
            if character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                runs.insert(current)
                current = ""
            }
        }
        if !current.isEmpty { runs.insert(current) }
        return runs
    }
}
