# Reply-language blind sets

Read by `ReplyLanguageBlindSetTests`, which runs `ReplyLanguage.detect` over every turn and
ratchets the result. Each file is a JSON array of turns:
`{"id", "text", "expected", "unreadable_ok", "note"?}`. `expected` is the language the reply
should come back in (`en` for an English question with a foreign greeting, quote or paste);
`unreadable_ok` means "no read" is an acceptable answer for a non-English turn.

- `reply-language-blind-1.json` — batch 1, 150 turns, written 2026-11-19 as a blind set for the
  challenger pass. **No longer blind:** the detector was tuned against it after its first run
  on 2026-11-19 (134 → 137/150, wrong-language clauses 3 → 0), so it is a regression set now,
  not a measure of how the detector generalises.
- `reply-language-blind-2.json` — batch 2, 105 turns, written fresh on 2026-11-19 after that
  tuning: foreign openers on English questions, CJK / Arabic / Cyrillic pastes, romanised
  Hindi / Arabic / Japanese / Tagalog / Persian. Still blind when it was checked in; keep it
  that way by fixing the detector on lines written in `ReplyLanguageTests`, never on these.

Re-run after every macOS / iOS update (Apple's `NLLanguageRecognizer` can move its reads
without a code change here):

    nice -n 15 tools/dev/tdd.sh M1K3ChatTests ReplyLanguageBlindSet

Signed: claude-opus-5-5, 2026-11-19, Confidence 0.8 (the sets are one author's lines). Prior: Unknown
