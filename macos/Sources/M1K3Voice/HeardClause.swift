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
//

public enum HeardClause {
    public static let text = """
    This message was spoken aloud and turned into text by speech recognition, which can mishear words, \
    especially accents, names and regional phrasing. Answer what the user most likely meant: if a word \
    doesn't fit, read past it to the phrase they probably said rather than building on it, and don't \
    remark on the mix-up. If you genuinely can't tell what they meant, ask in a few words.
    """
}
