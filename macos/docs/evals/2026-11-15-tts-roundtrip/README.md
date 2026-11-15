# Kokoro → Whisper round trip, before and after #838's number rules (2026-11-15)

`M1K3_SELFTEST_TTSRT=1` (`M1K3App/TTSRoundTripStage.swift`): Kokoro (`bm_daniel`) speaks the 39 items of
`TTSRoundTrip.corpus`, WhisperKit `small.en` transcribes each clip, and WordErrorRate scores each class
against the written or the spoken reading, whichever is closer. **Before** is master's G2P walker (ae8429af)
with the same stage; **after** is #838 slice 2. Same machine (M1 Max), same corpus, same voice and transcriber.

| Class | Words wrong, before | Words wrong, after | Keys heard, before | Keys heard, after |
|---|---|---|---|---|
| contractions | 2/39 (5.1%) | 2/39 (5.1%) | | |
| numbers | 10/85 (11.8%) | 3/93 (3.2%) | 4/18 | 18/18 |
| proper nouns | 9/50 (18.0%) | 9/50 (18.0%) | | |
| hard words | 13/58 (22.4%) | 14/58 (24.1%) | | |
| passage | 2/785 (0.3%) | 2/785 (0.3%) | | |

**Keys are the headline for numbers.** The word scorer's normaliser strips `-`, `£`, `/`, so the old walker's
"It was five overnight" for "-5" scored 0 errors. A key asks whether Whisper heard the thing at all ("minus" or
"-5"; "pounds" or "£"; "half" or "1/2"; "eighth" or "VIII"; "proposition"; "version"). The JSON's `keys` field
was recorded with the two colon keys before "10.30" (Whisper's British clock) and "3 16" were accepted; the
table recomputes both runs from their transcripts with the shipped keys (`TTSRoundTrip.numberKeys`).

**Noise.** Hard words are untouched by #838's rules and moved 25.9% → 20.7% in a first pair of runs and
22.4% → 24.1% in this one: about ±3 points run to run. Treat class moves under that as noise.

**Hard-word rate (fallback counts, after):** letter-to-sound spoke 13.6% of hard-word words, 12.0% of proper
nouns (one proper-noun word was silent), 0.1% of the passage, none of contractions or numbers.

**Limits.** Whisper's language model forgives a lot: this measures intelligibility, not accent or stress. The
passage is 785 words, 177 s at Kokoro's pace (about three minutes, not the five #838 asked for). The year-or-count
call ("1500 people") is invisible here, since Whisper writes digits either way: that one is the ear's. The clips
and transcripts stay in the container's `tmp/tts-roundtrip/`; this folder carries numbers only.

Owed by ear (TestFlight notes): a sample of each class, "1500 people" vs "in 1984", and Henry VIII.
