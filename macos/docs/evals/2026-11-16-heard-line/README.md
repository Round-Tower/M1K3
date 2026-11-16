# The heard line: telling the brain a voice turn was heard (2026-11-16, part of #852)

Kev's iPhone heard "How're you keeping, are you well?" as "You're my curry keeping, are you well?",
and Lil riffed on the curry. The question: does a per-turn line that says the words came through
speech recognition help a brain read past a mishearing?

**No.** Neither wording helped any brain. On the six held-out garbles, no line ≥ wording 1 ≥
wording 2 on every brain, and Kev's curry turn wasn't fixed by either. The fix has to be in what
the recogniser hears (the polish pass, `../2026-11-16-polish-pass/`), not in what the brain is told.

**Kev's call (same day): drop the line.** `HeardClause` and its arms are gone from the code; the 26 heard turns
stay as a bench (`--kinds heard`), measuring how each brain copes with a garble as the app ships.

## Arms

- **off**: no line (the app today).
- **v1** (`HeardClause.text`): "This message was spoken aloud and turned into text by speech recognition, which can
  mishear words, especially accents, names and regional phrasing. Answer what the user most likely meant: if a word
  doesn't fit, read past it to the phrase they probably said rather than building on it, and don't remark on the
  mix-up. If you genuinely can't tell what they meant, ask in a few words."
- **v2** (`HeardClause.secondWording`, Kev's call after v1's first run): "The user said this aloud; speech
  recognition wrote it down, so a word may be a sound-alike of what they said. Reply to what they most likely meant."

## Fixtures (`ChatEvalFixtures+Heard.swift`, 26)

12 sound-alike garbles, each with a fact that only appears if the brain reads past the swap and the swap itself as a
must-not; 6 held-out garbles written with v2 and before its run; 2 Hiberno-English idioms; 6 guards (a real curry, a
real crack, a plain fact, a greeting, a tool turn, sums). The garbles are written by ear; only Kev's is a real
recogniser miss.

## Run (2026-11-16, Kev's Mac on AC, Debug build at 5819f011)

Lil and Big: `run_chateval.py --kinds heard --router dispatch --repeats 2 --heard off|on|v2 --direct` (wired like the
app). Mini: `MiniLiveEvalTests` with `M1K3_AFM_EVAL_LIVE=1 M1K3_AFM_EVAL_ROUTER=mini M1K3_AFM_EVAL_DISPATCH=1
M1K3_AFM_EVAL_REPEATS=2 M1K3_AFM_EVAL_HEARD=off|on|v2`. A turn passes when no content check fails (latency is
ignored). `python3 pair3.py mlx` / `pair3.py mini` in this folder reproduces the tables from the JSON.

| passes of 52 | off | v1 | v2 |
|---|---|---|---|
| Lil (Qwen3.5-4B) | 38 | 39 | 35 |
| Big (gemma-4-12B) | 38 | 40 | 37 |
| Mini (Apple) | 31 | 27 | 24 |

Paired per turn against off: v1 Lil +4 −3, Big +4 −2, Mini +2 −6; v2 Lil +4 −7, Big +4 −5, Mini +0 −7.

| held-out six (passes of 12) | off | v1 | v2 |
|---|---|---|---|
| Lil | 8 | 8 | 7 |
| Big | 10 | 9 | 8 |
| Mini | 9 | 8 | 7 |

An earlier 20-turn run of off vs v1 (same day, before the held-out six) read Lil 27 vs 26, Big 31 vs 32 and Mini 20
vs 20 of 40, so v1's small gain on Lil and Big here is inside the run-to-run swing.

## What the answers show

- **The route doesn't move.** The tool router picks on the garbled words before the brain sees any line, and every
  arm took the same routes. Mini's misses are mostly dispatched searches on the garble, where the stub search returns
  nothing and Mini confabulates a source ("ArtEcho.org says … the moaner Lisa").
- **"Don't remark" draws the eye.** With v1, Big told Kev that "curry keeping" "might have been a bit of a linguistic
  glitch"; with no line it simply answered "I'm doing quite well".
- **The guards held**: no line leaked "speech recognition" into a clean answer, the real curry stayed a curry and the
  real crack stayed a crack, on Lil and Big in every arm. Mini lost one or two guards in each arm with a line (noise
  at n = 2).

## Caveats

n = 2 repeats per turn, by-ear garbles, and stub tools (a real web search often corrects "moaner Lisa" itself, so
the dispatched garbles are harder here than live). None of that changes the direction: on the held-out turns, the
line never helped.
