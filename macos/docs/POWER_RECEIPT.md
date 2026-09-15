# The power receipt — what an answer costs, measured

> The eco cred, done the way the brains page is done: a number with its
> hardware, power mode, app build and method beside it, or no number at all.
> The tool is `tools/eval/power_receipt.py`; runs land in `docs/evals/` as
> `<date>-power-receipt-<brain>-<run>.json`.

## Where the cred came from

M1K3's first system prompt (August 2025) called him "an eco-conscious,
context-aware edge AI system running locally for privacy and sustainability",
the RAG prompt called him "a virtual eco friendly pet", and the CLI printed
🔋 Energy Saved, 🌊 Water Saved and a CO₂ figure after every session. The
numbers behind those lines were assumed, not measured: 0.0005 kWh per cloud
token, so a 100-token answer was credited with 50 Wh of cloud energy and local
was declared 85 % cheaper. Credible 2025 per-prompt figures for a hosted model
are two orders of magnitude lower (Google's published Gemini median text
prompt ≈ 0.24 Wh; verify the source before quoting it). The cred was true in
spirit and wrong in number. This document is the number.

## What can and cannot be measured (spiked 2026-09-15, M1 Max, macOS 27)

| Source | Root? | Reads | Verdict |
|---|---|---|---|
| `task_info(TASK_POWER_INFO_V2).task_energy` | no | CPU energy only — a 2 s Metal matmul burn at 6.6 TFLOP/s added 0.057 J | **Do not ship as "this answer cost X"**: the brain runs on the GPU and this cannot see it |
| `rusage_info_v4.ri_billed_energy` | no | never moved (thread exit included) | unusable |
| `powermetrics --samplers cpu_power,gpu_power` | **yes** | package watts, CPU + GPU + ANE, every 500 ms | **the receipt** — whole machine, so the machine must be quiet |
| `AppleSmartBattery` `InstantAmperage × Voltage` (IOKit, public) | no | whole-system draw, negative while discharging; on AC it reads the charge current | a live in-app readout is possible **on battery only**; on AC it must say nothing |

## Method

1. In a real Terminal (the `!` prompt has no tty for sudo):
   `sudo -b powermetrics --samplers cpu_power,gpu_power -i 500 -n 1200 -o ~/.cache/m1k3-power/<brain>-<date>.log`
2. `python3 tools/eval/power_receipt.py drive --brain <brain> --out <turns.json>` — holds a 30 s idle
   window, then asks ten ordinary questions through the shipping `m1k3 ask`, stamping each turn's
   wall-clock window. The turns are the product's own turns, not a harness's.
3. `python3 tools/eval/power_receipt.py report --log <log> --turns <turns.json> --out docs/evals/<file>.json --provenance '{…}'`
   — idle = median package watts over the idle window; each answer is billed the energy **above idle**
   integrated over its window; the summary is the median across answers.

**A run is valid only on a quiet Mac.** No builds or test runs, no other session working, the M1K3
window minimised or the avatar off (a mounted RealityView renders at display rate), nothing else
animating. The idle window should read single-digit watts on an M1 Max; the receipt's summary
carries `idle_min_watts` / `idle_max_watts` / `idle_samples` so the call is machine-checkable — if
the max is more than a few watts above the median, stop and note why.

**Two things about time.** powermetrics stamps each sample to the whole second, so at `-i 500`
two samples share one timestamp; the sample's duration is taken from its own header
(`(510.76ms elapsed)`), never from the gap between timestamps, and that is what the energy is
integrated over. `summary.sample_interval_seconds` is the median of those durations. Under
contention powermetrics' own loop slips, so a run captured at `-i 500` that reports an interval
well above 0.5 s was fighting for the cores — one more signal the run was not quiet.

## Runs

| Run | Date | Brain | Valid | Idle W | Median Wh / answer | Note |
|---|---|---|---|---|---|---|
| 0 | 2026-09-15 | Lil (Qwen3-4B DWQ) | **no** | 42.8 (min 18.1, max 76.4) | 0.028 (not to be quoted) | Another session ran `xcodebuild test` + a nine-model remote eval throughout; M1K3 at ~49 % CPU beside WindowServer; GPU a steady ~28 W in and out of answers. The answers never rose clearly above the floor. Method proven, number not. (The first cut of the tool billed each sample a whole second and read 0.054; the per-header duration fold halved it — the #353 review's interval catch.) |
| **1** | 2026-09-15 22:08 | Lil (Qwen3-4B DWQ) | **yes** | **1.09** (min 0.5, max 9.9; 50 of 58 samples under 3 W, eight brief ones at 3–10 W while Kev used the Mac — the median did not move) | **0.058** (mean 0.059; 10 answers; median 6.1 s, 679 chars) | Quiet Mac: no builds, other session done, M1K3 windows hidden, Kev at the Mac with a browser open. Package power during an answer 35–43 W (median 37 W; median peak 48 W) for 4–8 s, of which the GPU 32–41 W (median 34 W) and the CPU 1.6–4.1 W (median 3 W) — the split is in the JSON per turn. `docs/evals/2026-09-15-power-receipt-lil-run1.json`. |

## The number (run 1, Lil, M1 Max)

**A Lil answer costs about 0.06 Wh** — six seconds at ~37 W of package power above a 1 W idle,
34 W of it the GPU and 3 W the CPU (the receipt carries `mean_cpu_watts` / `mean_gpu_watts` per
turn, so that sentence is a field, not a shorthand). For scale, the figure Google published in 2025 for a median Gemini text prompt is about 0.24 Wh
(verify the citation before it goes on a page), so the same class of question answered here is
roughly a quarter of that — and it involves no datacentre, no network transfer, no cooling
water, and a chip that was already on. The attic's "energy saved" arithmetic, which credited the
cloud with 50 Wh per answer, was off by three orders of magnitude; the cred survives the
correction.

Not yet measured: Mini (Apple Foundation Models — expect the ANE line to matter) and Big
(gemma-4-12B), tokens per answer (v1 records chars), and a battery-powered run. Next: a row per
brain on `/brains` beside tokens per second, then the word "eco" goes back on the site's receipts
band and into the store copy, and one clause returns to the persona behind an A/B gate.

<!-- Signed: Kev + claude-fable-5.1, 2026-09-15 (launch night), Confidence 0.8. The spike
     verdicts are from three 40-line Swift probes run this session; run 0's invalidity is
     read off the same log (per-10-second buckets, tagged idle/turn) and `top` at the time.
     Open: a valid run, and the token count per answer (v1 records chars). Prior: Unknown
     (new file).
     Review: Kev + claude-fable-5.1, 2026-09-15 (22:15): run 1 recorded VALID — idle 1.09 W
     median over 58 samples (eight brief samples at 3–10 W while Kev used the Mac; judged by
     the median and the count above 3 W, not by the max alone), Lil median 0.058 Wh per
     answer, every figure read off the receipt JSON the tool wrote. Confidence now 0.85
     (n = 10 on one machine; Mini / Big / battery unmeasured).
     Review: Kev + claude-fable-5.1, 2026-09-15 (22:40): the #357 review caught "GPU ~35 W"
     standing in for package power — the receipt now carries the CPU / GPU split per turn
     (mean_cpu_watts / mean_gpu_watts + summary medians) and the prose quotes the fields:
     package 37 W median, GPU 34 W, CPU 3 W. Confidence 0.85. -->
