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
#    python3 tools/eval/brains_page.py --run <OUT>.json --json ../site/brains.json --html ../site/brains.html
#    regenerates m1k3.app/brains + brains.json (ADR 0004: documentation, never read by the app)
python3 tools/eval/scorecard.py \
  ~/Library/Containers/app.m1k3/Data/scorecard.txt --markdown scorecard.md
```

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

**Record `pmset -g | rg powermode` with any timing you publish.** A Low Power
Mode run reads 15–20% slower and looks exactly like a regression — it
invalidated one of our own comparisons on 2026-08-08.

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

## Results

Published scorecards live alongside this file as `BENCHMARK-RESULTS.md`, each
stamped with the date, the hardware, the app commit, and the `mlx-swift-lm`
revision it ran against. Generate your own with the steps above — the numbers
here are one machine's, and the point of publishing the method is that you do
not have to take them on trust.

---

*Signed: Kev + claude-opus-5, 2026-08-08, Confidence 0.9 (methodology and
reproduction steps are exactly what was run; the limits section is the part
that matters and is deliberately unflattering). Prior: Unknown.*
