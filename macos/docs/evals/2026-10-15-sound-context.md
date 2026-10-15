# Sound context: SoundAnalysis's built-in classifier as room context (2026-10-15)

Kev's question: could the built-in sound classifier give M1K3 general context? `SoundContext`
(pure) turns its windows into one short line for a turn ("music (guitar), a dog barking") and a
verdict: a listen with music or singing and no speaker isn't a turn (the old "wrote down the
lyrics" bug). `SoundContextListener` is the SoundAnalysis glue. Neither is wired.

`SNClassifySoundRequest(.version1)`: 303 labels, 1.5 s windows. Cost: 124 s of audio in 1.7 s
including model load (about 1.4% of real time), 63 MB resident. There is no TV or radio class:
a presenter's voice is speech.

## Corpus (`tools/eval/sound_corpus.sh`, built from audio already on the Mac)

- `speech/`: Kev's 30 STT clips (`~/.cache/m1k3-stt-corpus/2026-10-15`).
- `music/`: every Apple Loop named vocal, choir or vox (spoken-word FX included on purpose), 40
  instrumental loops picked with a fixed seed, and the 3 Photos Memories tracks: 378 files.
- `speech-over-music/`: 10 of Kev's clips over the Memories tracks and loops at measured
  speech-to-music ratios of 0, -5 and -10 dB (the music as loud as the voice, then louder).
- `other/`: pink noise, the app's dial-up loop.

`M1K3_SOUND_EVAL=1 swift test --filter SoundContextEvalTests`; raw: `2026-10-15-sound-context.json`.

| folder | expected | right |
|---|---|---|
| speech | take | **30/30** |
| speech over music (0 / -5 / -10 dB) | take | **30/30** |
| other (pink noise, the dial-up) | take | **2/2** |
| music | not a turn | 188/384 |

The live path agrees: every speech and speech-over-music file fed through
`SoundContextListener.append` in 100 ms buffers, as a mic tap would, gives the file path's
verdict (0 of 60 differ).

Context lines (from the first run, before the guards below): plain speech adds none (30/30); over music, "music" or "music (drums)" (22/30);
songs name what they hear ("music (a choir)", "music (synth)", "music (singing)").

## Where speech gets lost under music

Kev's clips over the Memories tracks, ten per ratio, by the best speech confidence in any window:

| voice vs music | speech ≥ 0.5 | speech ≥ 0.1 |
|---|---|---|
| +15 to -5 dB | 10/10 | 10/10 |
| -10 dB | 8/10 | 10/10 |
| -15 dB | 2/10 | 9/10 |
| -20 dB | 0/10 | 8/10 |

So the speech floor that keeps a turn is set low, 0.1: a dropped turn is the worse mistake.
The trade, over the 229 files read as music:

| speech floor | music caught | turns kept at 0 / -5 / -10 / -15 / -20 dB |
|---|---|---|
| 0.5 | 225 | 10 / 10 / 8 / 2 / 0 |
| 0.2 | 213 | 10 / 10 / 10 / 7 / 4 |
| **0.1** | **203** | **10 / 10 / 10 / 9 / 8** |
| 0.05 | 180 | 10 / 10 / 10 / 10 / 9 |

Of 74 vocal loops, 25 were confidently sung and none of those also read as speech ≥ 0.5; the 6
that did are spoken-word FX loops.

A first corpus mixed at a fixed gain (0.6) buried the voice under dense loops (speech 0.05) and
scored 5/10 on talking over music: that measured the mixing, not the classifier. The builder now
mixes at measured ratios.

## Guards from challenger and the pre-push review

- **Our own sound:** the Mac has no echo cancellation, so the dial-up and earcons reach the mic.
  `noteOwnPlayback()` makes the verdict `.take` for that listen: we never veto a turn over music
  we played.
- **A majority, not any:** music in more than half the windows, and at least two windows, so one
  ringtone or earcon in a quiet listen decides nothing. On the loops (music in a window and no
  speech: 197) the veto catches 197 under "any window", 152 at "two windows", 122 at a majority
  on music alone (188 with singing counted, the eval's figure). Apple's loops are short and
  gappy; a song playing in the room fills every window, which this corpus doesn't test.
- **No overlap:** 1.5 s windows that don't overlap (the default 0.5 put one bark in two windows,
  past the "two windows" mention rule).
- `crying_sobbing` is never announced (often an adult, maybe the user); only `baby_crying` is.
- A window that began before a `reset()` is dropped; ties order by name.
- Advice for wiring (Kev's call): run the verdict in shadow first (log it at `.notice`, take every
  turn) until live logs show no wrongly vetoed turn; veto only a listen with a transcript; mention
  alerts every turn but the rest only when they change; keep the line out of memory distillation.

## Caveats

All mixes are digital: no room, no speakers, no microphone between the music and the voice. One
speaker, quiet clips (peaks about -25 dBFS). Apple Loops are short and produced; no commercial
song with a lead vocal is in the set. The speech-floor sweep above used the default overlapping
windows; the final rule doesn't overlap. The thresholds are starting points, not tuned live.
