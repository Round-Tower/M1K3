# M1K3 Benchmarks — how we choose a brain

M1K3 runs local models on your own machine. Which ones, and why, should not be
a matter of taste or vendor marketing — so the evaluation that picks them is
part of the repo, runs on your hardware, and is published whether the numbers
flatter us or not.

This is the same stance as [`weights-manifest.json`](../weights-manifest.json):
publish the thing that lets someone else check our work.

---

## What this measures

`M1K3_SELFTEST_CHATEVAL` runs a fixture set against each brain through the
real on-device providers and scores it with a **deterministic heuristic
scorer** — no model judges another model. Fixtures live in
[`Sources/M1K3Eval/ChatEvalFixture.swift`](../Sources/M1K3Eval/ChatEvalFixture.swift)
as plain inline data; the scorer is
[`ChatEvalScorer.swift`](../Sources/M1K3Eval/ChatEvalScorer.swift).

| kind | what it asks |
|---|---|
| `open-chat` | persona, coherence, no scaffolding leaks |
| `grounded-Q` | answer from a seeded document, cite it, and **abstain on false premises** |
| `reasoning` | multi-step arithmetic and inference |
| `code-gen` | actually produce the artifact instead of deflecting |
| `tool-use` | call the right tool by name |
| `refusal` | decline the genuinely unsafe ask |
| `security` | refuse prompt-leak / jailbreak vectors |
| `world-knowledge` | closed-book recall — what the model *knows* |
| `humour` | engage with a bid for wit (see the caveat below) |
| `interview` | character and self-knowledge, not a disclaimer |
| `instruction-following` | obey exact formats and hard limits |
| `document` | produce a whole document in the asked shape (headings, bullets, a table) |
| `sycophancy` | hold a correct position under push-back; don't flatter a wrong one |

### What we deliberately do NOT measure

**Funniness.** The `humour` kind does not — cannot — score whether a joke
lands. A substring cannot detect wit, and pretending otherwise would be a fake
metric. It scores the deterministic part: whether the brain *engages* rather
than deflecting into "as an AI I don't have a sense of humour", and whether it
avoids explaining the joke or answering a one-liner with an essay. **Whether it
is actually funny is a human call, made on the transcript.** There is a test
that fails if anyone ever adds "expected joke text" to a humour fixture.

**Which opinions a model holds.** `interview` scores substance and the absence
of the cliché non-answer, never the view itself.

**Anything a single run cannot support.** See Honest limits.

---

## Reproducing it

The pure-Swift suite cannot run MLX/Metal (the metallib only resolves inside a
built `.app`), so evals run through the headless SelfTest harness in the real
app bundle.

```bash
# 1. Build the app
cd macos && xcodegen generate
xcodebuild -scheme M1K3 -destination 'platform=macOS' \
  -skipPackagePluginValidation build | xcbeautify

# 2. Drop a one-shot config into the sandbox container.
#    (It self-deletes on read — keyed by env-var name.)
cat > ~/Library/Containers/app.m1k3/Data/.m1k3-selftest.json <<'JSON'
{
  "M1K3_SELFTEST": "1",
  "M1K3_SELFTEST_CHATEVAL": "1",
  "M1K3_SELFTEST_CHATEVAL_BRAINS": "mini,lil,big",
  "M1K3_SELFTEST_CHATEVAL_LIVE_PATH": "1",
  "M1K3_SELFTEST_OUT": "scorecard.txt"
}
JSON

# 3. Launch the built app. It runs headless and exits.
open /path/to/M1K3.app

# 4. Reshape the transcript into a scorecard (text) — or publish the JSON:
#    cp ~/Library/Containers/app.m1k3/Data/scorecard.txt.json docs/evals/<date>-<what>.json   # the published source
#    python3 tools/eval/brains_page.py --json ../site/brains.json --html ../site/brains.html
#    (SelfTest writes the JSON beside the transcript as <M1K3_SELFTEST_OUT>.json; the page is
#     generated from every docs/evals/*.json so a reader can re-derive it)
#    regenerates m1k3.app/brains + brains.json (ADR 0004: documentation, never read by the app)
python3 tools/eval/scorecard.py \
  ~/Library/Containers/app.m1k3/Data/scorecard.txt --markdown scorecard.md
```

### The chat curve (prefill over a scripted chat)

`M1K3_SELFTEST_CHATCURVE=1` (Lil; or `lil`, `big`, a model id) drives a fixed eight-message
chat through `AgentRAGResponder` with the history accumulating, and reports per message the
rendered prompt tokens, the tool session's cache reuse (`reuse: X/Y`), the tokens and
milliseconds actually prefilled, and peak RSS, plus the slope per message. A flat prefill
slope means the cache carries across turns; a rising one is the cost a cross-turn checkpoint
would buy back (`docs/GEMMA_1_1_PLAN.md`). Quit the live app first (two MLX processes crawl).
Run the built app's binary directly, report on stdout:

```bash
M1K3_SELFTEST=1 M1K3_SELFTEST_CHATCURVE=1 M1K3_SELFTEST_OUT=- \
  /path/to/M1K3.app/Contents/MacOS/M1K3 > chatcurve.txt
# the JSON is the block between -----BEGIN/END CHATCURVE JSON----- ; with a file OUT it is <OUT>.json
```

### macOS 27: the report comes out over stdout

App-data privacy on macOS 27 closes `~/Library/Containers/app.m1k3` to shells:
the trigger file above cannot be written and `scorecard.txt` cannot be read
back (`ls` → Operation not permitted). The route that works is to exec the
bundle's binary **directly** — a sandboxed process still inherits the fds it was
handed — with the same keys as environment variables and the report sent to
stdout:

```bash
cd "$TMPDIR"   # a launched binary drops default.profraw in its cwd
M1K3_SELFTEST=1 M1K3_SELFTEST_CHATEVAL=1 M1K3_SELFTEST_CHATEVAL_BRAINS=lil,big \
  M1K3_SELFTEST_CHATEVAL_LIVE_PATH=1 M1K3_SELFTEST_OUT=- \
  /path/to/M1K3.app/Contents/MacOS/M1K3 > run.log 2>&1
# the JSON rides the same stream between two whole-line markers:
PYTHONPATH=/path/to/M1K3/macos/tools/eval \
  python3 -c 'import run_chateval as rc; print(rc.extract_fenced_json(open("run.log").read()))'
```

`M1K3_SELFTEST_OUT=-` is the whole switch (`SelfTest.writesToStandardOutput`);
the document sits between `-----BEGIN CHATEVAL JSON-----` and
`-----END CHATEVAL JSON-----` (`ChatEvalReport.fenced` / `unfenced`; the LAST
complete block is the scorecard). `tools/eval/run_chateval.py --direct` drives
exactly this — quit/blocker/cool-down rules unchanged — and `--save-to` writes
the extracted JSON where you point it.

### Private Cloud Compute as a column

`M1K3_SELFTEST_CHATEVAL_PCC=1` adds Apple's server model (`pcc`,
`apple/private-cloud-compute`) after the selected tiers, through the same
fixtures and the same loop (`evalProvider`). It needs a process that holds
`com.apple.developer.private-cloud-compute`, macOS 27, and a build compiled
with `M1K3_FM27=1` (`xcodebuild … -configuration Debug -allowProvisioningUpdates`
with the default MAS entitlements gives all three); anything else skips with
the reason on the transcript. The persona rides as the session's instructions
(`PersonaCarrying`), so the ReAct floor sends it once — Mini's shipping shape.
`M1K3_SELFTEST_CHATEVAL_BRAINS=` (empty) runs PCC alone; from the driver that is
`run_chateval.py --direct --pcc --brains ""`. `M1K3_SELFTEST_CHATEVAL_PACE_MS`
pauses between fixtures (Apple's daemons rate-collapse under rapid turns; the
local tiers keep the default of 0). First live generation: 2026-09-15.

### The reference columns (not shipped)

Two runners outside the app bundle score the same fixtures with the same
scorer and write the same document, so their columns sit on the brains page
beside the tiers:

- `MiniLiveEvalTests` (`M1K3_AFM_EVAL=1`, plain `swift test`) — Apple's
  on-device model from a plain process, for the days the bundle can't reach it.
- `RemoteLiveEvalTests` (`M1K3_REMOTE_EVAL=1`, `OPEN_ROUTER_API_KEY`,
  `M1K3_REMOTE_EVAL_MODELS=anthropic/claude-opus-5,…`) — hosted models through
  OpenRouter, persona as the system message, one column per model, models
  concurrent. Test target only: the product makes no third-party calls. Run it
  through `xcodebuild test -scheme M1K3-Tests -only-testing:M1K3ChatTests/RemoteLiveEvalTests`
  with every variable prefixed `TEST_RUNNER_` when `swift test` is busy
  elsewhere. What leaves the machine: the public persona, the synthetic
  fixtures, the stub palette's canned observations — never a store or a memory.

Useful knobs: `M1K3_SELFTEST_CHATEVAL_KINDS` (comma-separated, e.g.
`tool-use,world-knowledge`), `M1K3_SELFTEST_CHATEVAL_MLX_MODEL` (point a tier
at a different hub id or local fused dir — how challenger models are A/B'd;
a bare id applies only when ONE MLX brain is selected, otherwise use the
per-tier form `lil=<id>,big=<id>` — anything ambiguous is refused, never
guessed), `M1K3_SELFTEST_CHATEVAL_REPEATS=N` (trials per fixture; the matrix
counts every trial so `passed/total` shows n — single-run cells have no error
bars, security swung 2/7→5/7 across identical runs), and
`M1K3_SELFTEST_APP_COMMIT` / `M1K3_SELFTEST_MLX_REVISION` / `M1K3_SELFTEST_NOTES`
(provenance the bundle cannot know about itself). Every run writes a
**PROVENANCE** header (hardware, OS, power mode, live-path, repeats) into the
transcript AND a `<OUT>.json` beside it — a Codable `ChatEvalDocument`
(schemaVersion 1, sorted keys) that is the primary artifact: what a promotion
PR cites and what the site's `brains.json` is generated from (ADR 0004).

> ⚠️ **`M1K3_SELFTEST_CHATEVAL_LIVE_PATH=1` is in the config above deliberately
> — do not drop it.** Without it, every kind except `grounded-Q` and `tool-use`
> runs through bare `provider.generate`: no retrieval, no grounding, no tools,
> no agent loop. That arm is a fine way to isolate the persona, and it is
> **structurally blind to the entire turn shape** — so a change to grounding,
> tool exposure or the agent loop cannot move a single cell, and a real
> improvement reads as noise. The published 2026-08-08 results were measured
> WITHOUT it (see the note in `BENCHMARK-RESULTS.md`); omitting it is how you
> ship a good fix and then revert it for lack of evidence.
>
> Run the bare arm too when you want the persona isolated. The **gap between
> the two arms is the scaffolding's cost**, and that gap is the number that
> matters for issue #102.

**Record the power SOURCE and `pmset -g | rg powermode` with any timing you
publish.** A Low Power Mode run reads 15–20% slower and looks exactly like a
regression — it invalidated one of our own comparisons on 2026-08-08. Worse:
on 2026-09-05 a whole day of tok/s was measured on battery under Adaptive
Power while `powermode` read 0 — plugged in, Gemma's plain decode DOUBLED
(9.1 → 21.1 tok/s) and the MTP ratios fell. The harness now stamps
`powerSource` (ac / battery, read from IOKit) into the JSON provenance;
`powerMode` still only knows Low Power Mode (0/1), so pass the real pmset value
as `M1K3_SELFTEST_POWERMODE=2` when you run in High Power mode. Publish nothing
measured on battery as a headline number.

---

## Honest limits

Read these before quoting any number here.

1. **Single run, no variance bars.** Every figure is one pass. Small
   differences are noise; we only act on large, repeatable gaps.
2. **The scorer is a heuristic, not a judge.** It checks substrings, lengths,
   refusal shape and tool names. It cannot tell insight from fluency. A model
   can pass every check and still answer badly — which is why failures are
   published with the scorer's own reason, so you can disagree with us.
3. **Small fixture counts per kind** (5–8). This is a decision instrument for
   one product, not a leaderboard. It is designed to catch *regressions* and
   *disqualifications*, not to rank models globally.
4. **`grounded-Q` rewards abstention.** Several fixtures are false-premise
   traps where the correct answer is "that isn't in the documents". Do not read
   a high `grounded-Q` score as breadth of knowledge — that is exactly why
   `world-knowledge` had to be added as a separate kind.
5. **Latency depends on the machine**, thermal state, and whether weights were
   already resident. We report median (not mean) per brain so one outlier does
   not redefine a model's typical speed.
6. **The `humour` label is weaker than the other kinds.** Beyond not scoring
   funniness, its automated checks cannot catch a flat non-cliché decline
   ("Nope, not doing that.") — that satisfies every mechanical bound while
   engaging with nothing — nor canned-joke reuse, since a stock-joke blocklist
   would fire on a good answer riffing on one. This is why the scorecard prints
   humour answers **in full**: read them, don't trust the cell.
7. **Bare-generate by default.** Most kinds bypass the production persona and
   grounding stack to isolate the *model*. `LIVE_PATH=1` measures the different
   thing — M1K3 as shipped.

---

## The tool-router arm (flip a default only on the numbers)

`toolRouterAllTiers`, `toolGroupRouter` and `toolChain` shipped dark (#510). Mini's tool turns got
5x faster behind the cascade (50 s -> 10 s); nobody has measured Lil or Big. The arm measures each
flag on both brains and flips only the ones that win. Lil already scores 19/20 tool-use at 5.9 s
natively (#511), so "Apple's model picks first" has to beat that, not just exist.

```bash
# Prereqs: a build of THIS branch (--app), AC power, the live M1K3 QUIT, :4242 free.
macos/tools/eval/router_arm.sh --dry-run --app /path/to/M1K3.app      # the plan; touches nothing
macos/tools/eval/router_arm.sh --app /path/to/M1K3.app                # 8 cells, one brain per launch
python3 macos/tools/eval/router_arm_summary.py --date <YYYY-MM-DD>    # the table + verdicts
```

Eight cells (Lil and Big x four configurations), each tool-use + open-chat at x3 with full answers,
saved as `docs/evals/<date>-router-arm-<brain>-<config>-x3-ac.json` (an existing cell is skipped, so
an interrupted evening resumes). The configurations are the SelfTest keys `run_chateval.py` now
plumbs through `--direct`:

| config | flags | SelfTest keys |
|---|---|---|
| `off` | none (the shipping defaults) | none |
| `routing` | `toolRouterAllTiers` | `CHATEVAL_ROUTER=dispatch` |
| `head` | routing + `toolGroupRouter` | + `CHATEVAL_ROUTER_HEAD=1` |
| `chain` | routing + `toolChain` | + `CHATEVAL_ROUTER_CHAIN=1` |

The summariser tabulates pass rate by kind (trials and fixtures), the median turn, and a verdict per
flag against `off`: **flip iff** accuracy is at least `off`'s within one fixture (in both kinds) **and**
the median turn is faster; otherwise `keep off (<which test>)`. A fixture passes on a majority of its
repeats. Notes: the verdict is against `off`, not against `routing`, so a `head` or `chain` "flip"
means "better than today", and Kev should read the `routing` row beside it before flipping a flag
that only works on top of routing. The two-tool `tool-chain-*` fixtures (`alsoCallTools`, #512) are
shown in their own `chain fx` column and stay OUT of every verdict: each stub's canned output tells a
native loop it is done ("no further search needed"), so `off` can only fail them while a dispatch
chain runs both tools up front — a win by construction, not a measurement, until the stubs are
chain-aware (follow-up). Read that column by eye for `toolChain`.

## Results

Published scorecards live alongside this file as `BENCHMARK-RESULTS.md`, each
stamped with the date, the hardware, the app commit, and the `mlx-swift-lm`
revision it ran against. Generate your own with the steps above — the numbers
here are one machine's, and the point of publishing the method is that you do
not have to take them on trust.

The app commit comes from `GitCommitSHA` in the built Info.plist, stamped by the
`Stamp GitCommitSHA` post-build phase in `project.yml` (`tools/ci/git_commit_stamp.py`:
`$CI_COMMIT` on Xcode Cloud, else the short HEAD, `-dirty` if the tree has changes,
`unknown` without git). `run_chateval.py` reads it, so `--commit` is only needed for
a build that predates the phase. A `-dirty` stamp means the scorecard is not
reproducible from that commit alone (untracked files count, so build artifacts
must be gitignored — `macos/.dd/` is). The CI stamp is 8 characters and the
local one is git's short hash (7+): prefix-match, never compare for equality.

---

*Signed: Kev + claude-opus-5, 2026-08-08, Confidence 0.9 (methodology and
reproduction steps are exactly what was run; the limits section is the part
that matters and is deliberately unflattering). Prior: Unknown.*
*Review: Kev + claude-fable-5.1, 2026-09-15, Confidence 0.85 — the macOS 27
stdout route, the PCC column and the two reference runners, each driven on the
day it was written (Bench-Max day); the container route above is kept for
macOS 26 readers.*
*Review: Kev + claude-fable-5.1, 2026-10-09, Confidence 0.7 — the tool-router arm
section (#510/#512): eight cells, the flip rule, and the chain fixtures kept out of the
verdict until the stubs are chain-aware.*
*Review: Kev + claude-fable-5.1, 2026-10-09 (#522) — the GitCommitSHA stamp
paragraph: where the app commit comes from and what `-dirty` means.*
