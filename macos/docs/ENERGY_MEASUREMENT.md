# Energy measurement — what M1K3 can know about its own cost

> **Rule zero: measure, never quote.** Every figure here carries the Mac, the date, the build and
> the method beside it. A figure that was not measured on this Mac says so, and a tier with no
> measured watts gets no number at all. #696 Phase 1. The first receipt, and the history of the
> "eco" claim, is `docs/POWER_RECEIPT.md`. This document builds on it and does not repeat its spike.

## The question, and the answer

**Can the sandboxed app read its own energy?** Its CPU energy, yes. The app read it from inside
its own sandbox on 2026-10-26, twice, with `sandboxed: true` both times. That was a Release build
of ca4e434e carrying the Mac App Store lane's entitlements, signed for development; the
`M1K3_SELFTEST_ENERGY` stage below has the details. The Developer ID lane carries the same
`app-sandbox` entitlement but was not built, so it stays **UNVERIFIED**.
`proc_pid_rusage(getpid(), RUSAGE_INFO_V6)` returns `ri_energy_nj` without root, and the probe read it inside an App
Sandbox. It does not see the GPU: a Metal burn that kept the GPU busy 1.94–1.99 s of a 2 s window moved it
0.009–0.045 J (four runs). A Lil answer is about 93 % GPU (run 1 in `docs/POWER_RECEIPT.md`: 34.42 of
37.14 W of package power), so no counter the app can read will ever say "this answer cost X".

So M1K3 does what the issue's fallback describes. `powermetrics` (root, run by hand) stays the
receipt. The app ships a per-tier coefficient (joules per prefilled token, joules per decoded
token) derived from receipts taken on one Mac, an M1 Max, and prices each generation's own token
counts. A tier with no receipt is unpriced.

## The counters (M1 Max 64 GB, macOS 27.0)

| Source | Root? | In the sandbox | Sees | Verdict | Measured |
|---|---|---|---|---|---|
| `task_info(TASK_POWER_INFO_V2).task_energy` | no | not tested | CPU only (a 2 s Metal matmul burn: +0.057 J) | instrument only | 2026-09-15, `docs/POWER_RECEIPT.md` |
| `rusage_info_v4.ri_billed_energy` | no | reads | never tracks the work (0 in a plain process; stray movement in a sandboxed one) | unusable | 2026-09-15; again 2026-10-26 |
| **`rusage_info_v6.ri_energy_nj`** (new) | **no** | **reads (rc 0)** | **CPU only** | an instrument and a future CPU term; never "this answer cost X" | 2026-10-26, below |
| `powermetrics --samplers cpu_power,gpu_power` | **yes** | n/a (a separate tool) | package watts: CPU + GPU + ANE | **the receipt**: whole machine, so the Mac must be quiet | 2026-09-15 runs 0 and 1 |
| `AppleSmartBattery` `InstantAmperage × Voltage` | no | not tested | whole-system draw, on battery only | a live readout on battery only; on AC it must say nothing | 2026-09-15 |

## The V6 probe (2026-10-26, M1 Max 64 GB, macOS 27.0 26A428, AC)

`tools/perf/energy_counter_probe.sh` reproduces it, with no root, app or model. It compiles one small
Swift program that opens three 2 s windows (idle, a one-core CPU burn, a Metal compute burn) and
prints how far each moved the counter. It runs the program twice: as a plain process, then ad-hoc
signed into an App Sandbox. The sandboxed run exits 2 before it reads unless the sandbox is on
(HOME is the container and a write to the real home is refused), and a positive control first
checks that the guard refuses an unsandboxed process. A refused read exits 3. Two runs of the
script as it is in the tree, that night, with the load average at 3.2–3.5 (lines marked
`annotation` are the invoking shell's, not the script's output):

    # run 1, 2026-10-26 21:42 (annotation)
    Apple M1 Max, macOS 27.0 (26A428), 'AC Power'
    == plain process
    sandbox: container none, HOME=/Users/kevinmurphy, write to /Users/kevinmurphy allowed
    device: Apple M1 Max
    idle rc=0 2.01 s  energy_nj Δ 0.000 J (0.00 W)  P-cores Δ 0.000 J  billed Δ 0
    cpu-burn rc=0 2.00 s  energy_nj Δ 6.576 J (3.29 W)  P-cores Δ 6.575 J  billed Δ 0
    gpu-burn rc=0 2.01 s  energy_nj Δ 0.012 J (0.01 W)  P-cores Δ 0.012 J  billed Δ 0
    the GPU was busy 1.99 s of the gpu-burn window
    == App Sandbox (ad-hoc signed)
    sandbox: container dev.scratch.m1k3-energy-probe, HOME=/Users/kevinmurphy/Library/Containers/dev.scratch.m1k3-energy-probe/Data, write to /Users/kevinmurphy refused
    device: Apple M1 Max
    idle rc=0 2.01 s  energy_nj Δ 0.000 J (0.00 W)  P-cores Δ 0.000 J  billed Δ 2224
    cpu-burn rc=0 2.00 s  energy_nj Δ 6.546 J (3.27 W)  P-cores Δ 6.543 J  billed Δ 0
    gpu-burn rc=0 2.01 s  energy_nj Δ 0.009 J (0.00 W)  P-cores Δ 0.009 J  billed Δ 1260
    the GPU was busy 1.99 s of the gpu-burn window
    # exit 0 (annotation: every check passed)
    # run 2, 2026-10-26 21:42 (annotation)
    Apple M1 Max, macOS 27.0 (26A428), 'AC Power'
    == plain process
    sandbox: container none, HOME=/Users/kevinmurphy, write to /Users/kevinmurphy allowed
    device: Apple M1 Max
    idle rc=0 2.01 s  energy_nj Δ 0.000 J (0.00 W)  P-cores Δ 0.000 J  billed Δ 0
    cpu-burn rc=0 2.00 s  energy_nj Δ 6.534 J (3.27 W)  P-cores Δ 6.530 J  billed Δ 0
    gpu-burn rc=0 2.01 s  energy_nj Δ 0.016 J (0.01 W)  P-cores Δ 0.016 J  billed Δ 0
    the GPU was busy 1.99 s of the gpu-burn window
    == App Sandbox (ad-hoc signed)
    sandbox: container dev.scratch.m1k3-energy-probe, HOME=/Users/kevinmurphy/Library/Containers/dev.scratch.m1k3-energy-probe/Data, write to /Users/kevinmurphy refused
    device: Apple M1 Max
    idle rc=0 2.01 s  energy_nj Δ 0.000 J (0.00 W)  P-cores Δ 0.000 J  billed Δ 1552
    cpu-burn rc=0 2.00 s  energy_nj Δ 6.560 J (3.28 W)  P-cores Δ 6.557 J  billed Δ 0
    gpu-burn rc=0 2.01 s  energy_nj Δ 0.034 J (0.02 W)  P-cores Δ 0.034 J  billed Δ 1280
    the GPU was busy 1.99 s of the gpu-burn window
    # exit 0 (annotation: every check passed)

Two earlier runs at 21:13 and 21:14, from the same measuring code before the script gained its
fail-closed checks (their figures are on the #696 thread), agree: a CPU burn moved it 6.45–6.73 J,
and a GPU burn 0.011–0.045 J while the GPU was busy 1.94–1.99 s.

What that shows:

1. **It moves without root.** A one-core burn moved it 6.45–6.73 J in 2 s (3.2–3.4 W), plain and
   sandboxed, on all four runs. Earlier the same evening, with a cold build compiling, scratch versions
   of the probe read 2.0–5.0 J over 1.5–2 s burns. The other load is the likely reason (not
   measured). Only the movement matters here, not its size.
2. **It is CPU only.** The GPU window moved it by 0.009–0.045 J while the GPU was busy 1.94–1.99 s
   of the 2 s. That is the CPU's own cost of waiting on the command buffer. The GPU's energy is
   invisible to it, as `task_energy`'s was in September.
3. **It reads inside an App Sandbox.** The sandboxed run's reads return rc 0 and move like the
   plain run's, and the run would have exited 2 had the sandbox not applied. The probe's sandbox
   is an ad-hoc signed command-line tool, not the shipping app. The app's own read was measured
   later the same evening (verify-by-launch, below): the Mac App Store lane's entitlements read it,
   twice. The Developer ID lane is **UNVERIFIED** (not built).
4. **`ri_billed_energy` stays useless.** In the plain process it stayed at 0 in every window. In the
   sandboxed one it moved by a few thousand units in some windows, burn or not, and never tracked
   the work. That field bills work other processes do on this one's behalf, and the sandbox's own
   services may be that (unverified). Either way it says nothing about the brain.

## The per-tier coefficients

Method: J per token = package watts above idle while the brain generates ÷ its tokens per second,
both measured on one Mac, an M1 Max 64 GB. On any other chip the rate is still that M1 Max's
figure, not the user's: every rate names its Mac (`measuredOn`) and its model (`modelID`), and no
surface may print it as the user's cost without saying whose it is. The table lives in code in one
place, `EnergyCoefficients` in `Sources/M1K3Inference/EnergyLedger.swift`. A test binds Lil's rate
to Lil's model id, so a model swap fails the suite and forces a re-derivation.

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

**One cross-check, from run 1's own answers, and it settles little.** Run 1 recorded characters,
not tokens. A least-squares fit of its ten answers (fitted 2026-10-26 from
`docs/evals/2026-09-15-power-receipt-lil-run1.json`) gives joules above idle ≈ 163 J + 0.080 J per
character (n = 10, R² 0.36). The slope's 95 % interval is −0.007 to +0.167 J per character. At an
assumed ~4 characters per token (an assumption, not a measurement) that is −0.03 to +0.67 J per
output token, centred on 0.32. It is consistent with the derived 0.43, and just as consistent with
a rate a third of that or half again, and it does not rule out zero. The marginal speed comes from
a second fit, seconds ≈ 4.1 s + 0.00272 s per character (R² 0.55): 367 characters a second, so
~92 tok/s at the same 4 characters per token (95 % interval about 53–350 tok/s). The two slopes
together imply ~29 W of marginal power, below the 36 W the rate uses.

The intercept, 163 J (95 % interval 103–223 J, so 49–107 % of the median answer's 209 J), is the
part of an answer that did not scale with its length; a 91-character answer still cost 176 J. What
it holds is open. A cold persona prefill alone is the same order: at the derived 0.060 J per token,
today's ~2,444-token Lil seed is about 147 J, and the ledger does price a cold prefill. Whether run
1's answers paid one is not in the receipt (its build's seed size and cache state are not
recorded). The rest of the `m1k3 ask` window (embedding, retrieval, Apple's tool picker on the ANE)
the ledger never sees. Only a same-build receipt with the ttft token counts separates the two.
**What holds by construction: the ledger prices generation only, so its figure is a floor for
generation, not a whole answer's cost.**

## What the ledger records (Phase 2)

- **Per generation**, from the process-wide `GenerationMetricsReporter` sink the Mac shell already
  installs, **billed to the model that ran it** (`GenerationMetrics.modelID`), never to the brain
  the picker shows. A deep dive re-points the MLX slot at Big with Lil still selected, so billing
  the picker would price Big's heaviest work at Lil's rate. A model id that is a tier's stock model
  is that tier. Anything else, an audition under its own name or a report with no id, is counted
  as unattributed and never priced. An audition imported under the stock repo's own name carries
  that name, so it is billed as that tier.
- **The prefill it prices** is `prefilledTokens`, what this generation actually prefilled past a
  warm persona-prefix cache. `promptTokens` is the true context and would bill the cached
  ~2,444-token Lil persona again on every turn. It falls back to `promptTokens` only when the
  reporter does not know.
- **Kept: token counts, never joules.** A daily rollup per calendar day (per tier: generations,
  prefilled tokens and decoded tokens; plus a count of unattributed generations) for 30 days, as
  one JSON blob under the UserDefaults key `energy.days`. Joules are priced on read, at the table
  the running build ships. So Kev's ruling on the derived Lil rate, or a calibration, re-prices the
  history, and a tier that loses its rate shows nothing. The stored fields are numbers, dates and
  tier names only, never message text. A test pins the JSON keys, every leaf, and the types, with a
  positive control (`Tests/M1K3InferenceTests/EnergyLedgerTests.swift`). Under the screengrab
  harness it records nothing.
- **Privacy, and a question for Kev.** The shape borrows the 2026-08-30 heartbeat ruling for pulse
  tags, "structural only": a tag "describes the shape of a window, never its content" (the
  pulse-tags addendum in `docs/HEARTBEAT_DESIGN.md`). The same ruling says a tag's "counts are
  banded, never exact". The ledger is not a pulse tag, so that clause does not bind it today, but
  it does keep exact per-day, per-tier counts on the Mac for 30 days. Nothing leaves the Mac and
  there is no text; whether exact counts are acceptable is Kev's call (open). Any Phase 3 pulse line
  fed from the ledger bands its counts.
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
  copy is reviewed against rule zero before anything ships, and a figure priced off a rate
  measured on another chip says so.

## Verify-by-launch: the in-app read (`M1K3_SELFTEST_ENERGY`)

`M1K3App/EnergyProbeStage.swift` reads the counter inside the sandboxed app. It loads Lil and does
everything one-time OUTSIDE the measured window: it builds the persona seed `generate` reuses
(cold; with no tools it measured 1,736 tokens on Lil, the context of 1,762 less the 26 prefilled)
and runs one short throwaway generation for first-use setup,
printing the warm-up's seconds. Then it reads the counter around one plain generation (thinking
off, 256-token cap) and prints the CPU joules, the generation's tokens, and the estimate the ledger
would record for them, so both figures describe the same work. Run it alone, with no live M1K3 and
nothing else on the MLX slot (it runs the SelfTest's core stages first):

    APP=$(python3 macos/tools/eval/build_eval_app.py <worktree> ~/Development/m1k3-infer-dd --configuration Release)
    M1K3_SELFTEST=1 M1K3_SELFTEST_ENERGY=1 M1K3_SELFTEST_OUT=- \
      M1K3_SELFTEST_MODEL=mlx-community/Qwen3.5-4B-MLX-4bit "$APP/Contents/MacOS/M1K3"

Expect `✓ energy: V6 read inside the app (sandboxed: true)`. The CPU share of the estimate is not
predicted here. Run 1's median CPU power was 3.0 W against 36.05 W of package power above idle
(about 8 %), so a share of that order would be unsurprising, and the stage measures it. A `✗` on the first line means the
shipping sandbox refuses the read: then the counter is gone as an instrument, and nothing else
changes.

### Measured: 2026-10-26, two runs

M1 Max 64 GB, macOS 27.0 26A428, AC, powermode 2. A Release build of ca4e434e (1.3.0) with the
default entitlements, `M1K3App/M1K3-MAS.entitlements` (`app-sandbox` true), signed with an Apple
Development certificate. Run as the command above, directly exec'd under `caffeinate -dis`, with no
live M1K3 and nothing else on the MLX slot. The transcripts, whole, are
`docs/evals/2026-10-26-energy-probe-lil-run1.txt` and `-run2.txt`. Run 1's stage lines:

    ✓ energy: V6 read inside the app (sandboxed: true) energy_nj=16251553132 billed=34081944145
    • energy: warm-up outside the window (persona seed + one throwaway generation): 3.35 s
    energy gen [mlx-community/Qwen3.5-4B-MLX-4bit]: 1.46 s, context=1762 prefilled=26 decode=115 tok @ 85 tok/s, 564 chars
    energy cpu (measured, CPU only): 3.041 J over the window (2.08 W), P-cores 3.041 J, billed Δ 1216
    energy estimate (lil, uncalibrated, rate measured on Apple M1 Max, 64 GB): 51.5 J = 26 × 0.0601 + 115 × 0.4343; the CPU counter saw 5.9 % of it

Run 2's:

    ✓ energy: V6 read inside the app (sandboxed: true) energy_nj=15150773844 billed=3963861986
    • energy: warm-up outside the window (persona seed + one throwaway generation): 3.43 s
    energy gen [mlx-community/Qwen3.5-4B-MLX-4bit]: 1.70 s, context=1762 prefilled=26 decode=135 tok @ 85 tok/s, 709 chars
    energy cpu (measured, CPU only): 3.459 J over the window (2.04 W), P-cores 3.459 J, billed Δ 18999
    energy estimate (lil, uncalibrated, rate measured on Apple M1 Max, 64 GB): 60.2 J = 26 × 0.0601 + 135 × 0.4343; the CPU counter saw 5.7 % of it

| Run | In-app read | Window | Prefilled / decoded | CPU J (measured) | CPU W | Estimate J (derived, ±50 %) | CPU ÷ estimate |
|---|---|---|---|---|---|---|---|
| 1 | ok, `sandboxed: true` | 1.46 s | 26 / 115 | 3.041 | 2.08 | 51.5 | 5.9 % |
| 2 | ok, `sandboxed: true` | 1.70 s | 26 / 135 | 3.459 | 2.04 | 60.2 | 5.7 % |

What the two runs show, and what they do not:

- **The read works in the shipping sandbox.** Both runs read the counter inside the app, under the
  Mac App Store lane's entitlements, and both windows moved. The counter is usable in the app as an
  instrument. A store-signed or notarized build was not run; the sandbox entitlement is the same,
  the signing certificate is not.
- **A warm Lil generation drew 2.04–2.08 W of CPU** by this counter. That is 5.7–5.9 % of the
  derived estimate. The two figures are different quantities: the counter is this process's CPU
  energy, while the estimate is package watts above idle. So the ratio gives an order of magnitude,
  not a split. It agrees in order with run 1's receipt (CPU 3.0 W of 36.05 W above idle, about 8 %).
  It does not check the estimate: the rest is the GPU, which no in-app counter sees, and the Lil
  rate is still derived.
- **The P-core figure equals the total to the millijoule** in both windows, as in the probe's burns.
  By the counter's own account, no energy in the window was billed to the efficiency cores.
- **`ri_billed_energy` moved 1,216 and 18,999 units**, and its opening values differed tenfold
  between the runs. It still does not track the work.
- **The warm-up outside the window took 3.35 and 3.43 s.** It is printed, not hidden, and the
  window holds only the warm generation the ledger prices.

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
     records it (read off MLXBrainProvider and BrainServeController). Confidence 0.85.
     Review: Kev + claude-opus-5.5, 2026-10-26 (pre-push review fold) — billing by the generating
     model, not `selectedBrain` (a deep dive's Big generations were priced at Lil's rate); tokens
     kept and joules priced on read; the headline says the shipping app's read is UNVERIFIED; the
     run-1 cross-check restated with its intervals (it cannot tell 0.1 from 0.43 J per token, and
     the intercept may be a cold persona prefill the ledger does price); the heartbeat ruling quoted
     in its own words, its banding clause named, exact counts put to Kev; the probe re-run twice
     with its fail-closed checks and re-quoted; the probe stage's warm-up moved outside its window.
     Confidence 0.8.
     Review: Kev + claude-opus-5.5, 2026-10-26 (eval stage) — the in-app read, measured: EnergyProbeStage
     ran twice on a Release build of ca4e434e (MAS entitlements, development-signed, sandboxed: true):
     CPU 3.041 and 3.459 J over 1.46 and 1.70 s, 5.9 and 5.7 % of the derived estimate. This retires the
     signature's Open on the in-app read for the Mac App Store lane. The Developer ID lane stays
     unverified (not built), and every tier's same-build receipt still needs sudo. The verify section's
     "~2.4k-token" seed became the measured 1,736 (the bare key, no tools). Confidence 0.85. -->
