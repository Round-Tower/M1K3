# Kokoro → Whisper round trip, before and after #838's number rules (2026-11-15)

`M1K3_SELFTEST_TTSRT=1` (`M1K3App/TTSRoundTripStage.swift`). Kokoro (`bm_daniel`) speaks the 39 items of
`TTSRoundTrip.corpus`. WhisperKit `small.en` transcribes each clip. WordErrorRate then scores each class:
the error count is the lower of the written and spoken readings, and the word count is always the spoken
reading's. **Before** is master's G2P walker (ae8429af) running the same stage. **After** is #838 with its
review fold. Both use the same machine (M1 Max), corpus, voice and transcriber. `before.json` and
`after.json` are the stage's own `TTSRTREPORT` lines, unedited.

| Class | Words wrong, before | Words wrong, after | Keys heard, before | Keys heard, after |
|---|---|---|---|---|
| contractions | 2/39 (5.1%) | 2/39 (5.1%) | | |
| numbers | 10/100 (10.0%) | 3/100 (3.0%) | 4/18 | 18/18 |
| proper nouns | 9/50 (18.0%) | 9/50 (18.0%) | | |
| hard words | 14/58 (24.1%) | 15/58 (25.9%) | | |
| passage | 2/785 (0.3%) | 2/785 (0.3%) | | |

No clip failed in either run.

**Keys are the headline for numbers.** The word scorer's normaliser strips `-`, `£` and `/`. So the old
walker's "It was five overnight" for "-5" scores 0 errors. A key asks whether Whisper heard the thing at all,
as a whole word or as its symbol:
- "minus" or "-5"
- "pounds" or "£"
- "half" or "1/2"
- "eighth" or "VIII"
- "proposition"
- "version"

The keys are listed in `TTSRoundTrip.numberKeys`. Two keys were widened after a first run's transcripts were
read: Whisper writes a British "10.30" for "ten thirty" and "3 16" for "three sixteen". Treat those two as
tuned. The other sixteen were written before any run.

**Noise.** #838's rules don't touch hard words. Across three pairs of runs, hard words moved 25.9% → 20.7%,
22.4% → 24.1% and 24.1% → 25.9%, about ±3 points from run to run. Treat any class move smaller than that as
noise.

**Hard-word rate.** From the fallback counts in the after run, letter-to-sound spoke:
- 13.6% of the hard words
- 12.0% of the proper nouns (one proper-noun word was silent)
- 0.1% of the passage
- none of the contractions or numbers

**Limits.**
- Whisper's language model forgives a lot. This measures intelligibility, not accent or stress.
- The passage is 785 words, 177 s at Kokoro's pace: about three minutes, not the five #838 asked for.
- The year-or-count call ("1500 people", "the context is 2048") is invisible here, because Whisper writes
  digits either way. That one is for the ear.
- The clips and transcripts stay in the container's `tmp/tts-roundtrip/`. This folder carries numbers only.

Owed by ear (in the next build's TestFlight notes): a sample of each class, "1500 people" against "in 1984",
and Henry VIII.
