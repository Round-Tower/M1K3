//
//  HeardClause.swift
//  M1K3Voice
//
//  The line every voice-first turn hands the brain (#852): these words were heard, not typed. Kev said
//  "How're you keeping, are you well?" on his iPhone (2026-11-16); the recogniser wrote "You're my curry
//  keeping, are you well?" and the brain, with nothing to say the text could be wrong, riffed on the curry.
//
//  It rides the per-turn clauses (`VoiceTurnPreparer.Prepared.turnClause` → `TurnClauseSlot` → the
//  responder's `voiceClauseProvider`), never the question, so it stays out of chat history and memory
//  distillation, and out of the cached persona prefix. Typed chat and dictation never carry it.
//
//  It names no example: the heard eval's garbles (`ChatEvalFixtures+Heard.swift`) must not leak into
//  the line that is under test (a test pins that).
//
//  Signed: Kev + claude-opus-5-5, 2026-11-16, Confidence 0.6 (wording unmeasured until the heard arm
//  runs on Lil / Big / Mini). Prior: Unknown.
//  Review: Kev + claude-opus-5-5, 2026-11-16 — the first arm measured no help (Lil 26 vs 27 of 40 without it, Big 32
//  vs 31, Mini 20 vs 20; same routes either way), and on Kev's curry turn Big named the "glitch" despite "don't remark".
//  Kev: try a second wording. `secondWording` is shorter and says only what happened and what to answer, nothing about
//  mix-ups; `forArm` lets the eval run either. Written before the rerun, which adds six held-out garbles. Confidence 0.5.
//

public enum HeardClause {
    public static let text = """
    This message was spoken aloud and turned into text by speech recognition, which can mishear words, \
    especially accents, names and regional phrasing. Answer what the user most likely meant: if a word \
    doesn't fit, read past it to the phrase they probably said rather than building on it, and don't \
    remark on the mix-up. If you genuinely can't tell what they meant, ask in a few words.
    """

    /// The second wording under test (#852): what happened and what to answer, nothing about the mix-up itself.
    public static let secondWording = """
    The user said this aloud; speech recognition wrote it down, so a word may be a sound-alike of what they \
    said. Reply to what they most likely meant.
    """

    /// The eval's arm (`M1K3_SELFTEST_CHATEVAL_HEARD`, `M1K3_AFM_EVAL_HEARD`): `off` is no line, `v2` the second
    /// wording, anything else the shipped one.
    public static func forArm(_ arm: String?) -> String? {
        switch arm {
        case "off": nil
        case "v2": secondWording
        default: text
        }
    }
}
