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

The first valid run publishes to `/brains` beside tokens per second, and only then does the word
"eco" go back on the site and into the store copy. Until then the honest line is the one 1.0
already earns: no datacentre, no transmission, no cooling water, and a chip that was already on.

<!-- Signed: Kev + claude-fable-5.1, 2026-09-15 (launch night), Confidence 0.8. The spike
     verdicts are from three 40-line Swift probes run this session; run 0's invalidity is
     read off the same log (per-10-second buckets, tagged idle/turn) and `top` at the time.
     Open: a valid run, and the token count per answer (v1 records chars). Prior: Unknown
     (new file). -->
