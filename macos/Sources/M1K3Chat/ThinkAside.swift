//
//  ThinkAside.swift
//  M1K3Chat
//
//  "The Tell" (2026-11-20): when a speed-tier brain decides a turn needs real thought, M1K3 says so in one plain
//  line before the quiet. The 2026-11-20 A/B put Lil's puzzle answers at a ~40 s median with thinking on, against
//  7 s off; a spinner for 35 s reads as a hang, an announced quiet reads as work.
//
//  Honest by construction: the line is said only after `ThinkingPolicy.shouldThink` chose to think, before any
//  generation, and it claims nothing else. No numbers, durations or progress words (nothing the wait could
//  disprove), and not "puzzle": the think also fires on explain / compare / debug asks and in Always mode. Never
//  generated; never in a prompt, the replay, distillation or the answer text (`ChatMessage.thinkAside` is
//  transient). The look is the villain, never the voice: plain and warm.
//
//  Signed: claude-opus-5-5, 2026-11-20, Confidence 0.7 (the rules are tested; whether the words land is Kev's
//  ear, and the set is a first draft to read aloud). Prior: none (new file).
//  Review: Kev + claude-opus-5-5, 2026-11-20 — Kev shipped `steps` for Lil and took the steer: the caption and the
//  pulse stay immediate, and voice says the line only after `spokenDelay` (6 s) of real quiet. Confidence 0.75.
//

import Foundation

public enum ThinkAside {
    /// The lines, in the person's language (whole sentences, one key each).
    public static var lines: [String] {
        [
            String(localized: "Hang on, this one needs real thought.", bundle: .module,
                   comment: "Said before M1K3 thinks hard. Plain and warm; no time or progress claims."),
            String(localized: "Let me think this one through.", bundle: .module,
                   comment: "Said before M1K3 thinks hard. Plain and warm; no time or progress claims."),
            String(localized: "Right, let me work this out properly.", bundle: .module,
                   comment: "Said before M1K3 thinks hard. Plain and warm; no time or progress claims."),
            String(localized: "This one deserves a proper think.", bundle: .module,
                   comment: "Said before M1K3 thinks hard. Plain and warm; no time or progress claims."),
        ]
    }

    /// How long the caption must stand before voice mode says it aloud. Spoken at the decision, a think that
    /// answers in a few seconds gets a line that is all ceremony; spoken after a real quiet, it explains one.
    public static let spokenDelay: Duration = .seconds(6)

    /// Voice says the line only once it has stood for `spokenDelay` with no answer text (the caption goes the
    /// moment the answer starts, so a quick answer is never announced aloud).
    public static func shouldSay(shownFor elapsed: Duration) -> Bool {
        elapsed >= spokenDelay
    }

    /// The line for a conversation's `index`-th think: they rotate, so two in a row never repeat.
    public static func line(forThink index: Int) -> String {
        let all = lines
        guard index >= 0 else { return all[0] }
        return all[index % all.count]
    }
}
