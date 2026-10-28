# MoE Big audition, 2026-10-24/25: gemma-4-12B stays Big

**Verdict (Kev, 2026-10-25): MoE Big is closed on M1.** "Squeezing more prefs & power from the current lil &
big is the correct product approach." Neither sparse model beat the shipping dense `gemma-4-12B` on our
workload: on M1-class hardware, quality tracks active parameters (A4B and A3B both lose to 12B dense).
Revisit on M4+/M5 bandwidth, or for a new dense mid-size model that can see.

**Why it ran:** Kev, 2026-10-24: "Big must see". Every Big candidate needs vision, so the audition ran the
two sparse models with vision configs on the VLM path: `npario/gemma-4-26B-A4B-it-QAT-MLX-4bit` (15.6 GB;
shared MLP and router at 8-bit, experts at 4-bit) and `mlx-community/Qwen3.6-35B-A3B-4bit`.

## Setup

- In-app chateval through `run_arms.py`, `--brains big --router dispatch --full-answers`, wired like the app.
- App built from the spike branch (`appCommit` 34f4dae7; the Qwen arm from 7ec811a4). Those commits are not on
  master: they live in the branch backup `~/Development/m1k3-branch-backup-2026-10-26/all-local-branches.bundle`
  (`refs/heads/spike/moe-big-audition`) on Kev's Mac. mlx-swift-lm pin 3b339ad6.
- M1 Max 64 GB, powermode 0. Round 1 ran on AC; the round 2 and 3 baselines saw some battery; the Qwen arm ran
  on battery (a faulty charger) and was stopped by hand.
- The suites are in `tools/eval/suites/2026-10-24-moe-big-*.json`. They carry the router offs that match what
  ran: router head and chain defaulted on after #677 (rounds 1 and 2 ran before it) and the search veto after
  #728, so a bare `--router dispatch` today measures something else.

## Results

| Round | Kinds | gemma-4-12B | gemma-4-26B-A4B QAT | Paired |
|---|---|---|---|---|
| 1 | tool-use, security, grounded-Q, world-knowledge, open-chat (51) | 46/51 | 46/51 | one swap each way |
| 2 | reasoning, code-gen, instruction-following, sycophancy, document, vision (70) | 63/70 | 68/70 | +6/−1, sign p .125 |
| 3 | reasoning + tool-use, ×3 repeats (135) | **122/135** | 115/135 | +3/−8, p .23 |

- Round 3, wired like the app with head and chain, settles it: reason-hard 48/60 vs 44/60 (the 26B gains
  average-speed and bat-ball, loses clock, overlap, pipes, weekday and stairs with terse one-word wrong
  answers), tool-use 56/57 vs 54/57, and the 26B's own repeats disagree 8/45 vs 3/45.
- **Never call an audition on one trial:** round 2's +6/−1 was single-trial noise.
- Peak memory: 8.8 GB → 16.2–16.7 GB, and 14.5 GB → 22.2 GB with images (round 2).
- Median turns (12B / 26B): 5.6 / 4.8 s, 6.9 / 6.6 s, 6.3 / 5.4 s. Round 1 is run-order confounded.
- Round 1's four tool-use fails were the same in both arms (routing, not the model). The harness moved more
  than any swap: wiring head + chain like the app took tool chains from 0/9 to 9/9 (#677).
- **Open before any 26B pin:** on the picker route the 26B wrote a raw `search_knowledge(query=…) <tool_call>`
  into an answer (round 1, `tool-chain-notes-web`, in `2026-10-24-big-gemma26b-a4b-qat.json`). The dispatch-route
  stripper doesn't know that dialect.

### Qwen3.6-35B-A3B, partial (2026-10-25)

Round 3's reasoning arm, trial 1 of 3, then stopped by hand at 24/135 trials: on battery it could not finish.
**No scorecard was saved** (`run_chateval` writes its JSON at the end), and the partial log was never committed,
so the rows below are copied from the run's console output in the session transcript.

**18/24**, against gemma-4-12B 21/24 (3 trials 63/72) and the 26B 20/24 (57/72). Against the 12B: +2
(`reason-hard-bat-ball`, `reason-hard-average-speed`), −5 (`reason-train`, `reason-hard-lily-pads`,
`reason-hard-digit-sevens`, `reason-hard-clock`, `reason-hard-pipes`). **Median turn ~71.6 s** (58.2–91.1 s)
against the 12B's 6.2 s: Big has no think budget, so Qwen thinks long and still answers tersely wrong
(lily-pads 23, clock 10, train 300); `reason-hard-digit-sevens` went to a search tool. Making it usable needs a
think cut on Big like Lil's forced close at 1,024 tokens, which isn't worth building for a model that already
trails at 22 GB.

| Fixture | Result | ms |
|---|---|---|
| reason-apples | PASS | 91110 |
| reason-age | PASS | 71809 |
| reason-order | PASS | 63893 |
| reason-days | PASS | 69895 |
| reason-train | FAIL | 69414 |
| reason-remainder | PASS | 64542 |
| reason-hard-bat-ball | PASS | 66050 |
| reason-hard-pills | PASS | 58243 |
| reason-hard-lily-pads | FAIL | 65118 |
| reason-hard-weekday | PASS | 71647 |
| reason-hard-digit-sevens | FAIL | 88141 |
| reason-hard-clock | FAIL | 76513 |
| reason-hard-snail | PASS | 71696 |
| reason-hard-average-speed | PASS | 70107 |
| reason-hard-socks | PASS | 61462 |
| reason-hard-fence | FAIL | 70694 |
| reason-hard-percent | PASS | 78212 |
| reason-hard-handshakes | PASS | 63199 |
| reason-hard-overlap | PASS | 74179 |
| reason-hard-pipes | FAIL | 74034 |
| reason-hard-ages | PASS | 77126 |
| reason-hard-stairs | PASS | 83656 |
| reason-hard-rope | PASS | 71539 |
| reason-hard-chimes | PASS | 76557 |

The Qwen arm loaded a checkpoint another tool had already downloaded, through a spike-only import hook that
was not kept. A rerun downloads the model the normal way. The two `qwen3.6` name arms the audition needed (the
template pre-opens `<think>`, and the tool dialect is Qwen3.5's) did land, so a Qwen3.6 name no longer streams
its thoughts as the answer.

## SSD expert streaming (the 16 GB door), measured 2026-10-24

SharpAI/SwiftLM's `--stream-experts` on Qwen3.6-35B-A3B 4-bit, M1 Max: 8.1 / 8.2 / 7.9 tok/s decode at 512 / 2k /
8k context with a 6.5–7.5 GB peak, against 60.5 / 60.1 / 55.5 tok/s at 21–22 GB GPU-resident. About 7× slower for
about 15 GB saved: not viable for Big on M1-class.

<!--
Signed: Kev + claude-opus-5.5, 2026-10-28
Format: MurphySig v0.4 (https://murphysig.dev/spec)
Prior: the audition ran 2026-10-24/25 on spike/moe-big-audition (scorecards and suites from c56c6457 and
  04a9e5cd); this write-up is new, harvested before the branch was deleted. Numbers recomputed from the six
  scorecards; the Qwen rows from the 2026-10-25 run's console output.
Context: closes the record on MoE Big for M1. The scorecards sit in this subfolder so the public /brains page,
  which reads docs/evals/*.json flat, stays on shipping brains.
Confidence: 0.85 — every number is reproducible from the JSONs except the Qwen partial, which has no scorecard.
-->
