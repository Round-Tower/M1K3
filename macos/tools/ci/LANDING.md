# Landing a PR — the runbook

The rulings behind `land.sh` and `pr_watch.py`, moved here verbatim from the root `CLAUDE.md` on
2026-11-07 so that file can keep a six-line PR loop. **Nothing here is new; `pr_watch.py` enforces the
mechanics, `test_pr_watch.py` pins them.** A contributor's path is `CONTRIBUTING.md` → "Getting a PR
merged"; this page is the maintainer's and the agents'.

## The loop

- **Landing a PR:** `macos/tools/ci/land.sh <PR> [--passes N]` gates on
  `pr_watch.py` (required CI green on the head sha, review passes read against
  that head, each owed pass ending `VERDICT: APPROVE @ <full 40-char head sha>`;
  a short sha refuses), squash-merges by sha, verifies `state`+`mergedAt`. **One pass is
  the default, whatever the size** (2026-10-04 ruling — PR size is free, rounds
  are the cost): the auto bot pass fires on Swift, the manifest, `project.yml`,
  `macos/tools/**` and the workflows; a docs-only PR gets no auto pass, so summon
  once (twice if it touches CLAUDE.md, SECURITY.md or `.claude/`: `RISK_PROSE`, prose
  that steers agents, is a risk surface). Spend the review effort BEFORE the first push (`code-quality-reviewer`
  on the diff, one per ~400-line slice in parallel) and fold every finding in
  ONE push; nits go to the follow-up list in the PR body.
  **Run `pr_watch.py` / `land.sh` without `--passes`: the gate infers it.** It
  asks for 2 (auto + one summon) when the diff touches a risk surface
  (`RISK_SURFACE_PATTERNS` in `pr_watch.py`: agent script execution, MCP /
  Keychain, entitlements, Info.plist, dependencies, privacy and Private Cloud,
  crypto, release/CI config, agent-steering prose). GRDB migrations live inside `*Store.swift`, so
  they are read off the tree and the patch instead. Also pass `--passes 2`
  yourself when a fold changed logic. Going BELOW the inferred count needs
  `--why "<reason>"` (exit 5 otherwise). For two passes, push then summon AT
  ONCE so both read the same head, and fold both in one commit. Fastlane,
  `.entitlements`, `.xcprivacy`, `Info.plist`, Gemfile, `.xcconfig`, `ci_scripts` and agent prose sit
  outside the auto pass's paths (`AUTO_PASS_PATTERNS`), so there
  "2" means two summons. Trivial head (comment fold, clean master merge on a
  passed head): `--passes 0 --why "trivial head: <what>"` on ANY diff. Since
  #550 a bare `--passes 0` exits 5, risk surface or not, and a pass already on
  the head must still approve. `land.sh` never waits: pending CI exits 2 and merges
  nothing — run `pr_watch.py <PR>` first.
- **PR granularity (2026-09-30 ruling):** one PR per stream of work per day;
  same-day small fixes ride TOGETHER (a token strip, a scorer check, a tool
  fix, a docs line, a gem bump were five PRs one day — ~12 review rounds and
  six Xcode Cloud archives for one PR's worth of diff). Split only for a
  release gate, an independent revert path, or a change that needs a
  reviewer's whole attention. At most two push-wait-fold rounds per PR (a
  round is a push plus its review, not a pass), then carry the rest to a
  follow-up issue. Claude pushes branches and runs `land.sh` itself (never a
  direct push to master); the auto-mode classifier wants one "land" from Kev in
  the conversation per batch. Land in a batch at the end of a stretch, and
  report only when something is landable, blocked or interesting. `challenger` before a PR that sets a threshold or heuristic,
  and score the heuristic on a blind set it wasn't tuned on (#713's word veto
  passed its tuning lines and failed a blind set, 10-28).
- **Try it on the device before the PR loop (Kev, #655).** For UI, voice or device work, iterate on the
  branch with local builds on the Mac and phone first, and open the PR when it feels right: a review round
  costs more than a rebuild. A device check a PR still owes when it lands goes into the next build's
  TestFlight notes (`macos/tools/asc/testflight.py notes`), so it gets run, not forgotten (Kev, 2026-10-28).
- **CI on a PR:** package-only diffs are gated by `swift test` (~4 min); the
  App-shell and iOS+visionOS xcodebuild jobs run only when their paths change
  (the `shell` / `mobile` filters in `ci.yml`). Every push to master
  that touches Swift builds all three (a docs- or tools-only push skips them) —
  a shell break lands, then is fixed forward.
- **Never merge master into a PR branch** unless git reports a conflict or the
  PR needs a fix from master to go green — each merge is a full CI + review
  cycle. A one-file, test-only fix that unblocks a PR rides in that PR, named
  in the body.

## Two same-day PRs, stacked PRs

- When two same-day PRs already exist and clash only on MurphySig Review lines, land them one after another
  (order them with a `git merge-tree` dry run), each fixing its own header conflict (Kev, 2026-10-28).
- Merge stacked PRs bottom-up; never `--delete-branch` on a stack base;
  `git rebase --onto` over a squash-merged base. `land.sh` DOES delete the merged
  branch, so retarget dependants first (`gh pr edit <N> --base master`) or GitHub
  closes them (#473 was lost this way, reopened as #474).

## Verify, never trust an exit code

A merge is verified by `gh pr view <N> --json state,mergedAt` (state MERGED and a timestamp), a push by
the remote head matching the local one, a deploy by what the live site serves. `land.sh` prints the
merge commit; read master's CI lanes on it after a Swift-touching merge.

<!--
Signed: Kev + claude-fable-5.1, 2026-11-07, Confidence 0.85
Prior: the root CLAUDE.md (Kev + Claude sessions, 2026-09-30 → 2026-11-05) — every ruling here is a verbatim move;
the dates and PR numbers inside the bullets are theirs.
Context: a reviewer's note relayed by Kev on 2026-11-07 ("the per-PR ceremony in CLAUDE.md is extremely heavy —
a new contributor can't parse it"). Kev: "The PR flow does need some leaning out." The rules were not the
problem, their placement was: rulings next to the scripts, a short loop in the file every session loads.
-->
