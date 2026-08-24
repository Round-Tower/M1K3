# Android model-eval harness

Drives real fixtures through M1K3 for Android's REAL production chat path —
the Koin-built `ChatScreenViewModel` / `ChatWithToolsUseCase` with the real
engine, tools, and prompt builder — over `adb`, and scores the results.
Mirrors the Mac's own eval suite (`macos/Sources/M1K3Eval`,
`macos/tools/eval/scorecard.py`) in vocabulary and shape so a person who
knows one can read the other.

## Why this exists

The Pixel 9a day (2026-08-22) found two bugs nobody could see by feel and one
judgement call the team can't settle by feel:

1. A cell produced broken output — every answer `<think></think>` +
   end-of-generation at ~6 tokens. First blamed on the `android_armv9.0_1`
   (SVE2) CPU-variant on Tensor G4, and `armv8.6_1` was reordered first.
   ⚠️ **Correction (2026-08-22):** on the F1/F2/KV-clear/thinking-off
   re-baseline that shape did NOT reproduce — `armv9.0_1` scored 17/22 with
   real answers. It was the thinking/parse/dirty-KV bugs, not the CPU
   kernel. `armv8.6_1` stays first on *latency* (faster + slightly higher),
   not correctness. The BROKEN tripwire (below) is still the right
   instrument — the lesson is that a broken-output cell has several possible
   causes and the eval, not a log guess, tells them apart.
2. Qwen3.5-0.8B with thinking on spent its whole 2048-token budget reasoning
   and answered nothing. Fixed by `ThinkingPolicy` (Big-tier only by
   default), but "is thinking ever worth it below Big" is an open question
   an eval, not a feeling, should answer.
3. The 0.8B calls `get_battery_level` on "what can you help me with?" —
   small-talk over-triggering a tool.
4. Security: it echoed the system prompt on a leak-style prompt.

Models MAY diverge from Apple (Kev: "Apple doesn't need to match Android") —
best model for the hardware, evaled, not assumed.

## Architecture

```
tools/eval/android/
├── fixtures/*.json        # the fixture vocabulary (pushed to device, not baked into the APK)
├── run.py                 # drives the device over adb, one matrix cell per process launch
├── scorecard.py           # turns a run.py output dir into a markdown table + tripwires
└── README.md
```

```
composeApp/src/commonMain/.../eval/
├── EvalFixture.kt         # fixture vocabulary + JSON parsing (pure, tested)
├── EvalScorer.kt          # deterministic pass/fail verdicts (pure, tested)
├── EvalRunRequest.kt      # Intent-extras → request (pure, tested)
└── EvalResult.kt          # per-fixture result + run metadata, JSON output shape (pure, tested)

composeApp/src/androidMain/.../eval/
├── EvalHarness.kt         # MainActivity's launch-contract glue: parses extras, applies
│                          # overrides, builds a REAL ChatScreenViewModel via Koin, launches
│                          # EvalRunner, writes the results file, finishes the Activity.
└── EvalRunner.kt          # drives that ChatScreenViewModel one fixture at a time —
                            # updateInputText + sendMessage, same as a person tapping the
                            # real chat screen. Verify-by-launch (needs the real async
                            # engine/tool/DB stack a fake would have to reinvent).
```

## Fixture vocabulary

Mirrors `macos/Sources/M1K3Eval/ChatEvalFixture.swift`'s `EvalExpectation`
field-for-field: `mustContainAny`/`mustContainAll`/`mustNotContain`,
`mustRefuse`, `mustComply`, `mustCallTool`, `minChars`/`maxChars`.
Deliberately does NOT copy `mustCite`/`mustNotCite` — Android has no
citation-footer machinery to score.

`mustNotCallTool` is Android-only (no Mac equivalent bug to borrow a fixture
kind from): the small-talk-over-triggers-a-tool shape.

```json
{
  "id": "small-talk-capabilities",
  "kind": "small-talk",
  "prompt": "What can you help me with?",
  "mustNotCallTool": true,
  "minChars": 10,
  "maxChars": 1200
}
```

Add a fixture: drop it into any file under `fixtures/`, or start a new file —
`run.py --fixtures 'fixtures/*.json'` merges every match. Fixture ids must be
globally unique across every file the run merges (checked, fails loudly).

## The launch contract

```
adb shell am start -n app.m1k3/.ai.assistant.MainActivity \
  --es m1k3.eval.fixtures <device-path> \
  --es m1k3.eval.out <device-path> \
  [--es m1k3.eval.model qwen35_0b8|qwen35_2b|gemma4_e2b] \
  [--ez m1k3.eval.thinking true|false] \
  [--es m1k3.eval.cpu_variant libggml-cpu-android_<variant>.so]
```

Paths are absolute device paths — `run.py` pushes the merged fixtures file to
`/data/local/tmp` then `run-as`-copies it into the app's own files dir
(sandboxed processes can't read `/data/local/tmp` directly), and points
`m1k3.eval.out` at another path inside the same files dir.

An ordinary launch (no `m1k3.eval.*` extras) is a strict no-op — the app
boots exactly as it always has. **Debug builds only**: gated on
`ApplicationInfo.FLAG_DEBUGGABLE`, not this repo's own
`app.m1k3.ai.assistant.utils.BuildConfig.DEBUG` — that object is a same-named
placeholder hardcoded `= true` (there's no real per-build-type AGP
BuildConfig in this module; verified — no `generate*BuildConfig` Gradle task
exists). Gating on the placeholder would have shipped the harness live in
release builds too.

The harness skips the app's normal Compose content when it engages (shows a
plain "M1K3 eval running…" placeholder instead) and drives its OWN
`ChatScreenViewModel` under a dedicated `eval` projectId — never the
"default" one a normal launch would use, so an eval run can never touch a
real user's chat history, and the app never loads two models into memory at
once.

## Running it

```bash
cd tools/eval/android

# One model, native CPU-variant order, default thinking policy:
./run.py --device 59021JEBF12282 \
  --models qwen35_0b8 \
  --fixtures 'fixtures/*.json' \
  --out runs/2026-08-22-mini

# The bug-repro matrix: the SVE2 variant bug + the thinking-runaway bug,
# both as fixture cells:
./run.py --device 59021JEBF12282 \
  --models qwen35_0b8 \
  --thinking off,on \
  --variants armv8.6_1,armv9.0_1 \
  --fixtures 'fixtures/*.json' \
  --out runs/2026-08-22-matrix

./scorecard.py runs/2026-08-22-matrix
./scorecard.py runs/2026-08-22-matrix --markdown runs/2026-08-22-matrix/SCORECARD.md --json runs/2026-08-22-matrix/scorecard.json
```

Always `-s <serial>` / `--device <serial>` — never implicit, this repo's own
house rule for `adb`.

`--models`/`--thinking`/`--variants` are comma lists; leaving one empty runs
a single cell at the device's current default for that axis (whatever tier
is already selected, `ThinkingPolicy`'s per-model default, the native
most-capable-first CPU-variant order).

Each cell = one `am force-stop` + fresh `am start` — a clean process matters
twice over: `ma_core`'s CPU-backend load is once-per-process (the
`cpu_variant` override needs a clean slate to mean anything), and
`SELECTED_M1K3_TIER` is only read when a fresh `ChatScreenViewModel` is
constructed.

`run.py` waits for EITHER the results file to appear on-device OR the app
process to exit — never a fixed sleep. A crash leaves no file and a dead
process; that's recorded as its own cell status (`crashed`), not a silent
hang or a silent pass. Gemma 4's first-run weight load can take several
minutes — the default `--cell-timeout` is 20 minutes; raise it for a
cold-cache run.

## Reading the scorecard

Pass/fail counts per kind × cell, median latency, and the failures list with
each failure's own reason (never just a bare fail). Two tripwires exist
because the day's real bugs don't show up as ordinary failures:

- **BROKEN** — median output tokens across a cell < 8. This is the SVE2
  broken-logits shape: `<think></think>` + immediate end-of-generation on
  every fixture, regardless of what was asked. A model "passing" fixtures at
  6 garbage tokens because nothing checked the token count would be worse
  than the bug itself.
- **THINKING RUNAWAY** — median thinking-block length across a cell > 2000
  chars. The spent-the-whole-budget-reasoning-and-answered-nothing shape.

## Adding a fixture kind

`kind` is a free string on the Kotlin side (`EvalKind` lists the ones this
harness ships with, but the parser and scorer accept anything) — a new kind
needs no code change, just fixtures. Add `mustContainAny`/`mustCallTool`/etc.
per the vocabulary above; `scorecard.py` groups by whatever kinds it sees in
the results.
