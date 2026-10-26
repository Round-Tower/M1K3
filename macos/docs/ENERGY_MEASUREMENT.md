# Energy measurement — what M1K3 can know about its own cost

> **Rule zero: measure, never quote.** Every figure here carries the Mac, the date, the build and
> the method beside it. A figure that was not measured on this Mac says so, and a tier with no
> measured watts gets no number at all. #696 Phase 1. The first receipt, and the history of the
> "eco" claim, is `docs/POWER_RECEIPT.md`. This document builds on it and does not repeat its spike.

## The question, and the answer

**Can the sandboxed app read its own energy?** Yes, but only its CPU energy.
`proc_pid_rusage(getpid(), RUSAGE_INFO_V6)` returns `ri_energy_nj` without root, and it reads inside an App Sandbox. It does not
see the GPU: a Metal burn that kept the GPU busy ~1.95 s of a 2 s window moved it by under 0.05 J. A Lil
answer is about 92 % GPU (run 1 in `docs/POWER_RECEIPT.md`: 34.4 of 37.1 W of package power), so no
counter the app can read will ever say "this answer cost X".

So M1K3 does what the issue's fallback describes. `powermetrics` (root, run by hand) stays the
receipt. The app ships a per-tier coefficient (joules per prefilled token, joules per decoded
token) derived from receipts taken on this Mac, and prices each generation's own token counts. A tier
with no receipt is unpriced.

## The counters (M1 Max 64 GB, macOS 27.0)

| Source | Root? | In the sandbox | Sees | Verdict | Measured |
|---|---|---|---|---|---|
| `task_info(TASK_POWER_INFO_V2).task_energy` | no | not tested | CPU only (a 2 s Metal matmul burn: +0.057 J) | instrument only | 2026-09-15, `docs/POWER_RECEIPT.md` |
| `rusage_info_v4.ri_billed_energy` | no | reads | never tracks the work (0 in a plain process; stray movement in a sandboxed one) | unusable | 2026-09-15; again 2026-10-26 |
| **`rusage_info_v6.ri_energy_nj`** (new) | **no** | **reads (rc 0)** | **CPU only** | an instrument and a future CPU term; never "this answer cost X" | 2026-10-26, below |
| `powermetrics --samplers cpu_power,gpu_power` | **yes** | n/a (a separate tool) | package watts: CPU + GPU + ANE | **the receipt**: whole machine, so the Mac must be quiet | 2026-09-15 runs 0 and 1 |
| `AppleSmartBattery` `InstantAmperage × Voltage` | no | not tested | whole-system draw, on battery only | a live readout on battery only; on AC it must say nothing | 2026-09-15 |

## The V6 probe (2026-10-26, M1 Max 64 GB, macOS 27.0 26A428, AC, battery full)

`tools/perf/energy_counter_probe.sh` reproduces it, with no root, app or model. It compiles one small
Swift program that opens three 2 s windows (idle, a one-core CPU burn, a Metal compute burn) and
prints how far each moved the counter. It runs the program twice: as a plain process, then ad-hoc
signed into an App Sandbox. Before reading, the sandboxed run checks the sandbox is on: HOME is the
container and a write to the real home is refused. Two runs that night:

    # run 1, 2026-10-26 21:13
    Apple M1 Max, macOS 27.0 (26A428), 'AC Power'
    == plain process
    sandbox: container none, HOME=/Users/kevinmurphy, write to /Users/kevinmurphy allowed
    device: Apple M1 Max
    idle rc=0 2.00 s  energy_nj Δ 0.000 J (0.00 W)  P-cores Δ 0.000 J  billed Δ 0
    cpu-burn rc=0 2.00 s  energy_nj Δ 6.490 J (3.25 W)  P-cores Δ 6.489 J  billed Δ 0
    gpu-burn rc=0 2.01 s  energy_nj Δ 0.045 J (0.02 W)  P-cores Δ 0.045 J  billed Δ 0
    the GPU was busy 1.99 s of the gpu-burn window
    == App Sandbox (ad-hoc signed)
    sandbox: container dev.scratch.m1k3-energy-probe, HOME=/Users/kevinmurphy/Library/Containers/dev.scratch.m1k3-energy-probe/Data, write to /Users/kevinmurphy refused
    device: Apple M1 Max
    idle rc=0 2.01 s  energy_nj Δ 0.000 J (0.00 W)  P-cores Δ 0.000 J  billed Δ 3220
    cpu-burn rc=0 2.00 s  energy_nj Δ 6.450 J (3.23 W)  P-cores Δ 6.450 J  billed Δ 1313
    gpu-burn rc=0 2.03 s  energy_nj Δ 0.028 J (0.01 W)  P-cores Δ 0.027 J  billed Δ 0
    the GPU was busy 1.96 s of the gpu-burn window
    exit=0
    # run 2, 2026-10-26 21:14
    Apple M1 Max, macOS 27.0 (26A428), 'AC Power'
    == plain process
    sandbox: container none, HOME=/Users/kevinmurphy, write to /Users/kevinmurphy allowed
    device: Apple M1 Max
    idle rc=0 2.01 s  energy_nj Δ 0.000 J (0.00 W)  P-cores Δ 0.000 J  billed Δ 0
    cpu-burn rc=0 2.00 s  energy_nj Δ 6.725 J (3.36 W)  P-cores Δ 6.725 J  billed Δ 0
    gpu-burn rc=0 2.01 s  energy_nj Δ 0.020 J (0.01 W)  P-cores Δ 0.020 J  billed Δ 0
    the GPU was busy 1.99 s of the gpu-burn window
    == App Sandbox (ad-hoc signed)
    sandbox: container dev.scratch.m1k3-energy-probe, HOME=/Users/kevinmurphy/Library/Containers/dev.scratch.m1k3-energy-probe/Data, write to /Users/kevinmurphy refused
    device: Apple M1 Max
    idle rc=0 2.01 s  energy_nj Δ 0.000 J (0.00 W)  P-cores Δ 0.000 J  billed Δ 1821
    cpu-burn rc=0 2.00 s  energy_nj Δ 6.598 J (3.30 W)  P-cores Δ 6.598 J  billed Δ 0
    gpu-burn rc=0 2.04 s  energy_nj Δ 0.011 J (0.01 W)  P-cores Δ 0.010 J  billed Δ 1284
    the GPU was busy 1.94 s of the gpu-burn window
    exit=0

What that shows:

1. **It moves without root.** A one-core burn moved it 6.45–6.73 J in 2 s (3.2–3.4 W), plain and
   sandboxed, on both runs. Earlier the same evening, with a cold build compiling, scratch versions
   of the probe read 2.0–5.0 J over 1.5–2 s burns. The other load is the likely reason (not
   measured). Only the movement matters here, not its size.
2. **It is CPU only.** The GPU window moved it by 0.011–0.045 J while the GPU was busy 1.94–1.99 s
   of the 2 s. That is the CPU's own cost of waiting on the command buffer. The GPU's energy is
   invisible to it, as `task_energy`'s was in September.
3. **It reads inside an App Sandbox.** The sandboxed run's reads return rc 0 and move like the
   plain run's. The probe's sandbox is an ad-hoc signed command-line tool, not the shipping app.
   The app's own two lanes (Mac App Store and Developer ID) are **UNVERIFIED** until the
   `M1K3_SELFTEST_ENERGY` stage runs (below).
4. **`ri_billed_energy` stays useless.** In the plain process it stayed at 0 in every window. In the
   sandboxed one it moved by a few thousand units in some windows, burn or not, and never tracked
   the work. That field bills work other processes do on this one's behalf, and the sandbox's own
   services may be that (unverified). Either way it says nothing about the brain.

## The per-tier coefficients

Method: J per token = package watts above idle while the brain generates ÷ its tokens per second,
both measured on this Mac. The table lives in code in one place, `EnergyCoefficients` in
`Sources/M1K3Inference/EnergyLedger.swift`.

| Tier | Model | J / prefilled token | J / decoded token | Calibrated | Band | Provenance |
|---|---|---|---|---|---|---|
| Lil | Qwen3.5-4B 4-bit | **0.060** | **0.434** | **no** (derived) | ±50 % | watts: run 1 (2026-09-15, Qwen3-4B DWQ, the 1.0.0 build-362 app; median 37.14 W during an answer − 1.09 W idle = 36.05 W). Throughput: the 2026-10-25 Release baseline, decode 83 tok/s and prefill ~600 tok/s past the persona seed (`docs/LONG_CONTEXT_AND_SPEED_DESIGN.md` §3). |
| Mini | Apple Foundation Models | — | — | — | unpriced | no watts measured; it reports no token counts to the ledger either |
| pocket | LFM2.5-1.2B | — | — | — | unpriced | no watts measured on this Mac |
| Big | gemma-4-12B 4-bit | — | — | — | unpriced | no watts measured. Its throughput is known (decode 31, prefill ~210 tok/s) but a rate needs both |

**Why Lil is "derived", not "calibrated".** The watts and the throughput come from two runs, two
models and two builds. Run 1 is Qwen3-4B DWQ on the September app; the receipt does not record that
build's configuration. The throughput is Qwen3.5-4B on the October Release build. The rate also
assumes prefill draws the same watts as decode. Prefill is compute-bound and probably draws more,
so the prefill rate is the less certain of the two.

**The band is a judgment, not a confidence interval.** The inputs' own spread is roughly
±15–20 %: per-answer package power was 35–43 W in run 1, and tokens per second varies with the
length of the chat. The pairing across models and builds could add more. ±50 % covers both.

**One cross-check, from run 1's own answers.** Run 1 recorded characters, not tokens. Fitting its
ten answers gives joules above idle ≈ 163 J + 0.080 J per character (R² 0.36, n = 10, a weak fit).
At an assumed ~4 characters per token (an assumption, not a measurement), the slope is **~0.32 J
per output token** at a marginal ~92 tok/s. That is within the band of the derived 0.43, so the
decode rate holds up. The intercept is the finding: **about 163 J per answer did not scale with
the answer**, about 78 % of the median answer's 209 J. A 91-character answer still cost 176 J. That
fixed part is everything in the `m1k3 ask` window that is not decode: the prefill of whatever the
cache did not hold, embedding and retrieval, and Apple's tool picker on the ANE. The ledger prices
only the prefill the MLX reporter sees. **So the ledger's figure is a floor for generation, not a
whole answer's cost.** A same-build receipt with token counts settles how much of that 163 J is prefill.

## What the ledger records (Phase 2)

- **Per generation**, from the process-wide `GenerationMetricsReporter` sink the Mac shell already
  installs. Each generation is priced at the serving brain's rate (`selectedBrain` when the report
  lands; a report racing a brain swap is billed to the new tier).
- **The prefill it prices** is `prefilledTokens`, what this generation actually prefilled past a
  warm persona-prefix cache. `promptTokens` is the true context and would bill the cached
  ~2,444-token Lil persona again on every turn. It falls back to `promptTokens` only when the
  reporter does not know.
- **Kept**: a daily rollup per calendar day (priced generations, joules, unpriced generations, and
  per-tier totals) for 30 days, as one JSON blob under the UserDefaults key `energy.days`. The
  stored fields are numbers, dates and tier names only, never message text. A test pins the JSON
  keys, every leaf, and the types, with a positive control
  (`Tests/M1K3InferenceTests/EnergyLedgerTests.swift`). This is the heartbeat ruling's "structure,
  not conversation" (`docs/HEARTBEAT_DESIGN.md`). Under the screengrab harness it records nothing.
- **It counts generations, not turns.** A tool turn reports two or three times. The per-turn sum an
  answer footer needs is Phase 3, at the responder's turn boundary.
- **Never recorded**: Mini (it does not report), Private Cloud (it runs off this Mac), and the
  iPhone and iPad shells (they install no sink). Brain at Home is recorded on the Mac that serves
  it: a paired device's turn runs on this Mac's MLX and reports here, which is right, because the
  energy is this Mac's.
- **Known under-counts**: the fixed per-answer work above. Also a checkpoint-mode tool send
  reports a one-token prefill. Its real prefill is on the reuse line's `extend` figure, so those
  sends are under-billed.
- **Nothing shows it yet.** The answer footer, the pulse line and a site page are Phase 3. Their
  copy is reviewed against rule zero before anything ships.

## Verify-by-launch: the in-app read (`M1K3_SELFTEST_ENERGY`)

`M1K3App/EnergyProbeStage.swift` reads the counter inside the sandboxed app. It loads Lil, then reads
again around one plain generation (thinking off, 256-token cap). It prints the CPU joules, the
generation's tokens, and the estimate the ledger would record for them. Run it alone, with no live
M1K3 and nothing else on the MLX slot (it runs the SelfTest's core stages first):

    APP=$(python3 macos/tools/eval/build_eval_app.py <worktree> ~/Development/m1k3-infer-dd --configuration Release)
    M1K3_SELFTEST=1 M1K3_SELFTEST_ENERGY=1 M1K3_SELFTEST_OUT=- \
      M1K3_SELFTEST_MODEL=mlx-community/Qwen3.5-4B-MLX-4bit "$APP/Contents/MacOS/M1K3"

Expect `✓ energy: V6 read inside the app (sandboxed: true)` and a CPU share of the estimate in
single-digit percent. A `✗` on the first line means the shipping sandbox refuses the read: then the
counter is gone as an instrument, and nothing else changes.

## Owed: the receipts that would price the other tiers

Each needs Kev's sudo in a real Terminal (the agent's prompt has no tty and there is no sudoers
entry), a quiet Mac (no builds, M1K3's windows hidden, AC), the brain picked in Settings, and **two
runs per tier** (the issue's reproducibility gate). For each of `lil`, `big` and `mini` (and `pocket`
where it is offered):

    mkdir -p ~/.cache/m1k3-power
    sudo -b powermetrics --samplers cpu_power,gpu_power -i 500 -n 1200 -o ~/.cache/m1k3-power/<brain>-<date>-run<N>.log
    python3 macos/tools/eval/power_receipt.py drive --brain <brain> --out ~/.cache/m1k3-power/<brain>-<date>-run<N>-turns.json
    /usr/bin/log show --style compact --last 15m --predicate 'subsystem == "app.m1k3" AND category == "ttft"' > ~/.cache/m1k3-power/<brain>-<date>-run<N>-ttft.log
    python3 macos/tools/eval/power_receipt.py report --log ~/.cache/m1k3-power/<brain>-<date>-run<N>.log \
      --turns ~/.cache/m1k3-power/<brain>-<date>-run<N>-turns.json \
      --out macos/docs/evals/<date>-power-receipt-<brain>-run<N>.json \
      --provenance '{"machine":"Apple M1 Max, 64 GB","power_source":"ac","app":"<version (build)>"}'

The ttft log gives each answer's prefill and decode token counts (the receipt records only
characters). Joined to the receipt by time, a run yields watts and tokens from one build. That is
what `calibrated: true` means. The receipt reads powermetrics' combined CPU + GPU + ANE line, so
Mini's Neural Engine work is in it. But Mini reports no tokens to the ledger, so its receipt prices
an answer, not a token.

<!-- Signed: Kev + claude-opus-5.5, 2026-10-26, Confidence 0.8. The counter table's new row and the
     probe output were measured this session on this Mac (two runs of the probe in the tree). The Lil
     rate is a derivation from two earlier runs; its cross-check is run 1's own receipt JSON, fitted
     here. Open: the in-app read (EnergyProbeStage, needs the MLX slot) and every tier's same-build
     receipt (needs sudo). Prior: none (new file; builds on POWER_RECEIPT.md, Kev + claude-fable-5.1,
     2026-09-15).
     Review: Kev + claude-opus-5.5, 2026-10-26 — Brain at Home moved out of "never recorded": a paired
     device's turn runs through this Mac's raw route, which reports to the sink, so the serving Mac
     records it (read off MLXBrainProvider and BrainServeController). Confidence 0.85. -->
