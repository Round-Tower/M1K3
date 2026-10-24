# Eval suites for `run_arms.py`

A suite is one JSON file: `python3 macos/tools/eval/run_arms.py <suite.json> [--dry-run]`.

- `app`: the one M1K3.app every arm runs. It is one binary per comparison, built by `build_eval_app.py`, which prints this path.
- `outDir`: where each arm's `<name>.json`, `.log` and `.driver.txt` land. An arm whose `.json` already exists is skipped, so a re-run resumes.
- `args` and `notes` (optional): the run_chateval flags and the note every arm shares.
- `arms[]`: each arm has `name` (the run name), `timeoutMin`, and optional `args` (added after the shared ones) and `notes` (joined after the shared note with ": ").
- run_arms sets `--name --app --direct --save-to --log --no-relaunch --timeout-min --notes` itself, so a suite may not set them. Unknown keys are refused.
- Relative paths resolve against the suite file, and `~` expands.
- The file is read once at the start, so editing it mid-run changes nothing that is queued.
- An app argument that starts with `-` needs the `=` form: `--app-arg=-thinkBudgetTokens`.

What a run leaves in `outDir`:

- An arm is done when its `<name>.json` is there and parses, whatever the exit code. A saved `.json` is final, and a re-run never retries that arm. That includes run_chateval's exit 8 (the scorecard was saved, then the app exited non-zero), which the run names. To re-run an arm, move its `.json` aside.
- `<name>.driver.txt` gets one `--- attempt` block per try, so a retry never erases the evidence of the try before it.
- `.run_arms-live-app` names the live copy that was running before arm 1. A resumed run reads it, so the live app still comes back after a stopped run. The file is deleted once the app is seen running again, so if it is still there, the reopen was UNVERIFIED.
- Exit 0 means every arm is done and the live app is back. Exit 1 means something needs a look: an arm with no scorecard, an exit 8, an eval app left running (named by pid, and nothing more is started), or a reopen that was not seen.

**Example only, not a record of what ran.** Since 2026-10-24 a bare `--router dispatch` means the Mac app's wiring (group head and chains on); a run before that date had both off, so pass `--no-router-head --no-router-chain` to repeat one. This is the 2026-10-18 budget-forcing A/B (`evals11.zsh`) written as a suite. Lil runs on Always with the reasoning kind at x2, in three arms: forced close at 1024 tokens, the 4,000-char cut, and forced close at 2048 tokens.

```json
{
  "app": "~/eval-dd/thinking-cap/Build/Products/Debug/M1K3.app",
  "outDir": "../../../docs/evals/2026-10-18-lil-thinking",
  "notes": "Budget forcing A/B, house sampling, Always",
  "args": ["--brains", "lil", "--router", "dispatch", "--thinking", "always", "--think-steer", "none",
           "--kinds", "reasoning", "--full-answers", "--repeats", "2"],
  "arms": [
    {"name": "2026-10-18-lil-force1024-always", "timeoutMin": 100, "notes": "forced close at 1024 tokens",
     "args": ["--app-arg=-thinkBudgetTokens", "--app-arg=1024"]},
    {"name": "2026-10-18-lil-cut4000-always", "timeoutMin": 110,
     "notes": "4,000-char cut and re-ask (the branch default)"},
    {"name": "2026-10-18-lil-force2048-always", "timeoutMin": 160, "notes": "forced close at 2048 tokens",
     "args": ["--app-arg=-thinkBudgetTokens", "--app-arg=2048"]}
  ]
}
```

<!--
Signed: Kev + claude-opus-5-5, 2026-10-18, Confidence 0.8, Prior: none (new file).
test_run_arms.py loads the example above, so the format and this page cannot drift apart.
Review: Kev + claude-opus-5-5, 2026-10-18 — added what a run leaves in outDir: a saved .json is final (exit 8
included), the driver file's attempts, the live-app note, and the exit codes.
-->
