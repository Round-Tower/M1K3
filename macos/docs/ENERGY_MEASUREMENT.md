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
token) calibrated from receipts taken on one Mac, an M1 Max, and prices each generation's own token
counts. A tier with no per-token receipt is unpriced.

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

Method: J per token = one phase's energy above idle ÷ the tokens it processed, prefill and decode
apart. The watts and the tokens come from one build on one Mac: the 1.3.0 (541) app on an M1 Max
64 GB, on AC, 2026-10-27, two runs per tier. A run (`tools/eval/power_run.zsh`, below) idles 30 s,
then asks the ten built-in questions through the app's own `m1k3 ask` while `powermetrics` samples
package power every 500 ms. `tools/eval/power_receipt.py rates` then times every generation's
prefill and decode by the app's ttft line and fits each phase's watts across the samples. On any
other chip the rate is still that M1 Max's figure, not the user's: every rate names its Mac
(`measuredOn`) and its model (`modelID`), and no surface may print it as the user's cost without
saying whose it is. The table lives in code in one place, `EnergyCoefficients` in
`Sources/M1K3Inference/EnergyLedger.swift`. A test holds each rate to within 1 % of its tier's two
committed receipts pooled (`docs/evals/2026-10-27-power-rates-<tier>-run<N>.json`) and binds it to
its tier's model id, so a model swap fails the suite and forces a new receipt.

| Tier | Model | J / prefilled token | J / decoded token | Calibrated | Band | Provenance |
|---|---|---|---|---|---|---|
| Lil | Qwen3.5-4B 4-bit | **0.0738** | **0.422** | **yes** | ±10 % at these prompt sizes | 2 runs, 20 generations, 665–1,007-token prompts; runs 0.0741 / 0.0736 and 0.4214 / 0.4223 |
| Big | gemma-4-12B 4-bit | **0.213** | **1.17** | **yes** | ±10 % at these prompt sizes | 2 runs, 20 generations, 666–1,016-token prompts; runs 0.2142 / 0.2116 and 1.1739 / 1.1659 |
| Mini | Apple Foundation Models | — | — | — | unpriced | measured per answer (below), but it reports no tokens, so a per-token rate would price nothing |
| pocket | LFM2.5-1.2B | — | — | — | unpriced | no receipt: this Mac offers Mini in that slot |

Each rate is the pooled figure (both runs' phase joules over both runs' tokens), to three figures.
Big has been priced only since this calibration; before it, its generations were counted and left
unpriced. A test holds the table's bold figures to the shipped constants.

**The raw evidence is committed**, in `docs/evals/2026-10-27-power-raw/`: each run's `powermetrics`
log (gzipped), its ttft lines, and its windows (the idle window and each turn's start, end,
question and answer length, never the answer's text). Running `report` and `rates` on them gives
every receipt in `docs/evals/` again, byte for byte.

### How the split was made

**Placing the samples.** `powermetrics` stamps each sample to the whole second, and a Lil prefill
lasts about 1.2 s, so the samples are placed on the clock first. They are laid end to end by their
own `(NNNms elapsed)` headers, at the one offset every whole-second stamp allows. The headers'
jitter (500–530 ms) pins that offset to ±1–6 ms in every run. If the sampling loop slips (a
gap no header covers), the next sample starts a new stretch with its own offset, and the gap stays
unsampled. All six of these logs place as one stretch. September's two each split once, after
their answers.

**Timing the phases.** The ttft line is logged when decode ends. A generation's decode is its
`decode` tokens ÷ (its tok/s + 0.5) before that stamp, because the line truncates the rate. Its
prefill is the `prefill` ms before that.

**Fitting the watts.** For every sample that touches a turn, its energy above idle is modelled as
prefill watts × the prefill seconds it holds, plus decode watts × the decode seconds, plus a third
term for the rest of the turn. The three are fitted by least squares over the run. Prorating
alone, giving each sample's average power to every phase it overlaps, reads low: a sample that
straddles a generation's edge spreads the generation's power over its idle half too. That gave
0.0675–0.069 / 0.401–0.404 J (Lil) and 0.205–0.208 / 1.155–1.156 J (Big). Each `rates` file keeps it as
`cross_check_prorated`.

**Checking it twice.** The data check the placement. Refitting with the ttft clock shifted across
±1 s in 0.05 s steps, the fit's error is smallest at 0.00 s in three runs. In the fourth (Big run 1)
0.00 and +0.05 s tie (3.55 W). Half a sample off, ±0.5 s, the error is 3–10 times larger (Lil 1.2–1.3 W
against 12.2 W, Big 2.9–3.6 W against 9.5–10.3 W). So the placement is right to within the 0.05 s step,
and the split is not off by a sample. An independent re-derivation was written blind to these numbers,
with its own parser, placement and an eight-phase fit. It agreed to 0.1 %, and it found the
prorating bias, the power-line glitch and the old receipt's binning error described below. Its
table is on the PR; its script is not committed.

| Run | Prefill W above idle | Decode W above idle | J / prefilled token | J / decoded token | Turn energy inside the generations |
|---|---|---|---|---|---|
| Lil 1 | 47.2 | 35.1 | 0.0741 | 0.4214 | 98 % |
| Lil 2 | 47.3 | 35.1 | 0.0736 | 0.4223 | 98 % |
| Big 1 | 47.7 | 37.2 | 0.2142 | 1.1739 | 100 % |
| Big 2 | 47.7 | 37.1 | 0.2116 | 1.1659 | 99 % |

What the runs show:

1. **The two runs agree within 1.3 %** (Big's prefill rate; the other three within 0.7 %). The band
   is wider, ±10 %, and is a judgment. In a scan of the committed logs (the scan itself is not
   committed), moving the alignment ±0.05 s moved Lil's pooled rates by up to 3 % (decode
   0.409–0.432), and ±0.1 s by up to 5 %. Big moved about 1 % either way. Big
   run 1 idled at 1.98 W against run 2's 0.31 W, on a busier Mac 80 minutes earlier, and its rates
   still agree. The blind check put the choice of its baseline at about ±4 %.
2. **Prefill draws more than decode**: about 47 W above idle against 35–37 W. The derived rate this
   replaces assumed one figure for both.
3. **The derived Lil rate held within its ±50 % band.** It was 0.060 / 0.434 J (September's watts
   paired with October's throughput). The calibration gives 0.0738 / 0.422, +23 % and −3 %.
4. **On this path the ledger's floor is nearly the whole answer.** In questions 1–9, 99–100 % of a
   turn's energy above idle falls inside its generation. The rest is a 0.1–0.3 s lead before
   prefill and a short tail. The exception is question 10 ("List four uses for a Raspberry Pi").
   On every tier it went to the web. On Lil its turn ran 10.2 and 12.4 s against 1.8–4.3 s for
   the other nine (the windows) and its prompt grew to 983 and 1,007 tokens against 665–869 (the
   ttft lines); Mini's answer cites a link (the answer text, not committed). On Lil and Big that
   left 5.9–6.6 s before its generation, which cost 11–24 J above idle that the ledger does not see. The question list calls
   itself "no web", so the built-in ten under-test the tool path.
5. **A decoded token is not a visible one.** The ledger prices decoded tokens, and so do these
   rates. A Lil answer of 137 characters decoded 23 tokens in one run and 43 in the other.
6. **What it does not cover.** These prompts were 665–1,016 tokens, the `m1k3 ask` path. A chat
   turn carries the persona seed (1,736 tokens on Lil, measured below), and a long conversation
   more. Attention cost grows with context, so a long chat's tokens probably cost more than these
   (not measured). One Mac, on AC.

**The power line.** `powermetrics` prints `GPU Power` twice per sample. The processor summary's
copy, which its `Combined` line is built from, now and then reads near 0 W for one sample and about
double the next: one to three times in each of today's Lil and Big logs, 10–13 times in each Mini
log, and 19 times in September's run 1.
The GPU section's own line holds steady, and the two sum to the same total over a run. The tool
reads the GPU section's line, because once a window is shorter than a second, which half-second
the energy lands in matters.

### Mini, per answer: a floor

Mini reports no token counts, so its receipt prices an answer. **Its idle was not quiet**: 4.08 and
3.82 W (CPU 2.79 and 2.51 W, GPU 1.28 and 1.32 W, Neural Engine 0: the receipts' `idle_*_watts`),
against 0.28–0.31 W in three of the four MLX runs. Nothing recorded what drew it (the run sampled
power, not tasks); a window still drawing would look like this. In run 1 the GPU part held through
every answer (`mean_gpu_watts` 1.12–1.17 W in all ten), so subtracting it was fair, if the CPU part
held too. In run 2 it stopped after the fourth answer (1.12–1.29 W, then 0.02–0.24 W), so answers
5–10 were billed against a baseline at least 1.1 W too high, about 9 J an answer.

With that said, an answer cost 21.8 J above idle in run 1 and 16.8 J in run 2 (means; medians 20.6
and 16.2 J). On the same ten questions Lil's cost 108 and 111 J and Big's 305 and 323 J. Mini's
answers were shorter, 325–371 characters on average against 491–585. Run 1 is the fairer figure;
both stay floors until a run on a quiet idle repeats them.

### The receipt, re-run

The six receipts in `docs/evals/2026-10-27-power-receipt-*` come from the tool as it is now. The
version that ran on the night assigned whole samples to a turn by their whole-second stamp, and
clipped every sample at zero. That read Lil's ten answers 5–7 % low in total and one of them 28 %
low, and Mini's 5–9 % high. Its idle maximum could also catch the first answer's first sample:
Lil run 2's "28.86 W" idle peak was a prefill sample. A receipt now counts each placed sample for
the part of it a turn holds, unclipped, and the idle is the samples wholly inside its window.
September's receipts in `docs/evals/` are as that night's tool wrote them. Re-run today, run 1
reads 0.0596 Wh a median answer against the 0.0581 it recorded.

## What the ledger records (Phase 2)

- **Per generation**, from the process-wide `GenerationMetricsReporter` sink the Mac shell already
  installs, **billed to the model that ran it** (`GenerationMetrics.modelID`), never to the brain
  the picker shows. A deep dive re-points the MLX slot at Big with Lil still selected, so billing
  the picker would price Big's heaviest work at Lil's rate. A model id that is a tier's stock model
  is that tier. Anything else, an audition under its own name or a report with no id, is counted
  as unattributed and never priced. An audition imported under the stock repo's own name carries
  that name, so it is billed as that tier.
- **The prefill it prices** is `prefilledTokens`, what this generation actually prefilled past a
  warm persona-prefix cache. `promptTokens` is the true context and would bill the cached Lil
  persona (1,736 tokens bare, more with tools) again on every turn. It falls back to `promptTokens` only when the
  reporter does not know.
- **Kept: token counts, never joules.** A daily rollup per calendar day (per tier: generations,
  prefilled tokens and decoded tokens; plus a count of unattributed generations) for 30 days, as
  one JSON blob under the UserDefaults key `energy.days`. Joules are priced on read, at the table
  the running build ships. So a calibration re-prices the history (this one will, the moment a
  build carries it, Big's kept days included), and a tier that loses its rate shows nothing. The stored fields are numbers, dates and
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
- **Known under-counts**: the per-answer work outside the generation. On an `m1k3 ask` answer that
  is 0–1 %, and a web search before the generation adds 11–24 J (above). Also a checkpoint-mode tool send
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
`docs/evals/2026-10-26-energy-probe-lil-run1.txt` and `-run2.txt`. The estimate lines price at the
derived rate that build shipped; 2026-10-27's calibration replaced it. Run 1's stage lines:

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
  rate was still derived then. At the rate calibrated on 2026-10-27 the same windows estimate
  50.5 and 58.9 J, so the CPU share is 6.0 and 5.9 %.
- **The P-core figure equals the total to the millijoule** in both windows, as in the probe's burns.
  By the counter's own account, no energy in the window was billed to the efficiency cores.
- **`ri_billed_energy` moved 1,216 and 18,999 units**, and its opening values differed tenfold
  between the runs. It still does not track the work.
- **The warm-up outside the window took 3.35 and 3.43 s.** It is printed, not hidden, and the
  window holds only the warm generation the ledger prices.

## Taking a receipt

Each run needs a real Terminal for sudo (the agent's prompt has no tty and there is no sudoers
entry), a quiet Mac (no builds, M1K3 hidden, AC) and the brain picked in Settings. Two runs per
tier are the reproducibility gate:

    zsh macos/tools/eval/power_run.zsh <lil|big|mini> <run number>

It refuses to start on battery, during a build, with M1K3 not answering, with another brain picked
or with that run's log already on disk. Then it asks for the password once, before the clock
starts. It records the idle, drives the ten questions and fails if any answer comes back empty. It
stops `powermetrics` once the log holds a sample past the last answer, pulls the ttft lines and
writes the receipt, plus the phase rates for an MLX tier. The raw logs stay in `~/.cache/m1k3-power`.
Copy the receipts into `docs/evals/`.

## Still owed

- **Mini on a quiet idle**, with `powermetrics`' `tasks` sampler on, to name what drew 4 W at idle
  in both of 2026-10-27's Mini runs.
- **A long-context receipt**: a chat turn with the persona seed, and a conversation at about 4k and
  8k tokens, to see how far the rates rise with context.
- **pocket**, on a device that offers it.
- **The Developer ID lane's in-app read** (not built).

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
     "~2.4k-token" seed became the measured 1,736 (the bare key, no tools). Confidence 0.85.
     Review: Kev + claude-opus-5.5, 2026-10-27 — the receipts. Kev ran two powermetrics runs per tier
     (Lil, Big, Mini) on the 1.3.0 (541) app. `power_receipt.py rates` places the whole-second samples on
     the clock, times each generation by its ttft line and fits each phase's watts. Lil is now calibrated
     at 0.0738 / 0.422 J and Big is priced at 0.213 / 1.17 J, the runs agreeing within 1.2 % and a blind
     re-derivation within 0.1 % (it caught the prorating bias, the power-line glitch and the receipt's
     whole-second binning, all folded). Mini is measured per answer, but its idle was not quiet, so that
     figure is a floor. This narrows the Open on same-build receipts to pocket. The run-1
     cross-check and its intercept discussion, which only argued about the derived rate, give way to the
     measured split (git history keeps them). The raw logs, ttft lines and answer-free windows are
     committed, and re-running the tool on them reproduces every receipt. Confidence 0.85: two runs a
     tier, one Mac, one prompt shape.
     Open: pocket's receipt; Mini on a quiet idle with the tasks sampler; a long-context receipt (the
     persona seed, 4k and 8k-token chats); the Developer ID lane's in-app read. -->
