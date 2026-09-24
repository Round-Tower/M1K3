//
//  SpokenName.swift
//  M1K3Voice
//
//  How M1K3 says its own name — two forms, one owner.
//
//  Everyday speech says "Mike": M1K3 is leetspeak for MIKE (1→I, 3→E), the
//  kill-or-commit ruling of 2026-08-16. `SpeechTextPolish` rewrites the raw name
//  to it in every spoken answer, and Kokoro's house lexicon agrees.
//
//  The self-introduction says the letters (Kev, 2026-09-24). Its line used to hand
//  the engine the raw string — "Hi, I'm M1K3 — but my friends call me Mike!" —
//  which Kokoro's lexicon (rightly, everywhere else) spoke as "Hi, I'm Mike — but
//  my friends call me Mike!", and AVSpeech as an alphanumeric jumble. So the
//  letters are written as WORDS, the ones Kokoro's own letter table uses for M and
//  K: every engine reads words, and no lexicon or rewrite can touch them.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-24, Confidence 0.85 (pure and
//  red-first; Kev picked "letters in the intro only" over letters everywhere and
//  over Mike everywhere. How AVSpeech voices "em one kay three" is verify-by-ear).
//  Prior: Unknown.
//

public enum SpokenName {
    /// The name in ordinary speech.
    public static let everyday = "Mike"

    /// The name's four characters, as words every engine reads the same way.
    public static let spelled = "em one kay three"

    /// The self-introduction — "Hear a sample" in onboarding and Settings, on
    /// both the Mac and the phone.
    public static let introduction = "Hi, I'm \(spelled) — but my friends call me \(everyday)!"
}
