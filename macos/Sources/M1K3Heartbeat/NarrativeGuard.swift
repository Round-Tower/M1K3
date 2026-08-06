//
//  NarrativeGuard.swift
//  M1K3Heartbeat
//
//  The confabulation tripwire between the model's narrative and the pulse
//  that gets stored. Heuristic by design: any digit run in the narrative
//  must already appear in the digest, so a model cannot quietly invent a
//  precise-sounding number ("battery hit 12%", "answered 47 questions").
//  Named limit: digit-free fabrication ("looks like rain") passes — the
//  bound there is the render prompt's add-nothing rule plus the fallback
//  asymmetry: a false REJECT costs style (the digest ships instead), a
//  false PASS is confined to unnumbered prose.
//
//  Signed: Kev + claude-fable-5, 2026-08-06, Confidence 0.85 (heuristic
//  limits named above; behaviour pinned by tests). Prior: none (new file).
//

import Foundation

public enum NarrativeGuard {
    /// A narrative longer than this is a runaway generation, not a pulse.
    public static let maxLength = 1600

    public static func validate(
        narrative: String,
        digest: String,
        maxLength: Int = NarrativeGuard.maxLength
    ) -> Bool {
        let trimmed = narrative.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength else { return false }
        let allowed = digitRuns(in: digest)
        return digitRuns(in: narrative).isSubset(of: allowed)
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
