# M1K3 — the local AI assistant for Mac (and iPhone / iPad / Vision Pro)

Privacy-focused, on-device AI: MLX inference, live voice, knowledge graph + RAG,
and an MCP server. **The live product is the Mac-native SwiftUI app under
`macos/`** (`M1K3App/`), on the Mac App Store as 1.x. The same portable
`macos/Sources/` package graph drives the iOS + visionOS shell under
`macos/M1K3iOSApp/`. The legacy Python surface lives only in git history before
`7545b4a4` (`git checkout 7545b4a4 -- attic` resurrects it).

## Start here
- **`macos/CLAUDE.md`** — build, test, architecture, conventions. Read it first.
- **`macos/docs/IOS_VISIONOS_PORT.md`** — the iOS / visionOS shell.
- **`app/CLAUDE.md`** — M1K3 for Android (KMP, slow burn).
- **`CONTRIBUTING.md` / `SECURITY.md`** — the public-repo contributor surface.
- M1K3's in-app MCP server (`127.0.0.1:4242/mcp`) needs its access token (#270): connect
  with `m1k3 login && m1k3 connect claude` (user scope). No repo `.mcp.json` — a project
  entry would shadow the authed user one.

## Session memory
`.claude/project-memory.md` is the private session chronicle: gitignored, never
`git add -f`, append-only (a `Write` lost 700 lines on 2026-09-15). It is **not
imported** — read its last block when a task continues prior work, not before.
Anything a cold session needs on turn one belongs below, not there.

## Standing carry-forwards
- **Landing a PR:** `macos/tools/ci/land.sh <PR> [--passes N]` gates on
  `pr_watch.py` (required CI green on the head sha, review passes read against
  that head), squash-merges by sha, verifies `state`+`mergedAt`. Small PR (under
  ~100 lines, no logic change): `--passes 1`, the auto bot pass only — it fires
  on Swift, the manifest, `project.yml`, `macos/tools/**` and the workflows; a
  docs-only PR gets no auto pass, so summon once.
  Substantive: two passes on the final head (auto + one summon). Trivial head
  (comment fold, clean master merge on a passed head): `--passes 0`. A summon
  reviews the head at RUN time — push first, then summon AT ONCE, so the auto
  pass and the summon read the same head; fold both in one commit (a nits-only
  fold is a trivial head). `land.sh` never waits: pending CI exits 2 and merges
  nothing — run `pr_watch.py <PR> --passes N` first.
- **PR granularity (2026-09-30 ruling):** one PR per stream of work per day;
  same-day small fixes ride TOGETHER (a token strip, a scorer check, a tool
  fix, a docs line, a gem bump were five PRs one day — ~12 review rounds and
  six Xcode Cloud archives for one PR's worth of diff). Split only for a
  release gate, an independent revert path, or a change that needs a
  reviewer's whole attention. Two review rounds per PR, then carry the rest
  to a follow-up issue. Claude pushes branches and lands via `land.sh` without
  asking per action (never a direct push to master); land in a batch at the
  end of a stretch, and report only when something is landable, blocked or
  interesting. `challenger` before a PR that sets a threshold or heuristic.
- **CI on a PR:** package-only diffs are gated by `swift test` (~4 min); the
  App-shell and iOS+visionOS xcodebuild jobs run only when their paths change
  (the `shell` / `mobile` filters in `ci.yml`). Every push to master or develop
  that touches Swift builds all three (a docs- or tools-only push skips them) —
  a shell break lands, then is fixed forward.
- **Never merge master into a PR branch** unless git reports a conflict or the
  PR needs a fix from master to go green — each merge is a full CI + review
  cycle. A one-file, test-only fix that unblocks a PR rides in that PR, named
  in the body.
- `xcodegen` after every checkout; `M1K3.xcodeproj` is a gitignored artifact.
- A worktree `xcodebuild` needs `-skipPackagePluginValidation -skipMacroValidation`.
- `swift package clean` before protocol/struct-shape changes (segfault, 3+ hits).
- swiftformat's unused-parameter rename runs BETWEEN batched edits: change a
  signature and its call sites in ONE edit, re-read before the next.
- Merge stacked PRs bottom-up; never `--delete-branch` on a stack base;
  `git rebase --onto` over a squash-merged base.
- Two MLX processes crawl — quit the live app before an eval run.
- iOS/visionOS MLX has ONE gate, `AppCore.mlxAvailable` (`MLXRuntimeSupport`):
  never on the Simulator or Apple GPU family 5 (A12/A12X/A12Z) — mlx-swift
  traps there, it never throws. Route any new MLX path through it.
- Bundle ID, log subsystem, Keychain and container are all `app.m1k3`.
- `.info` / `.debug` do not persist in OSLogStore; breadcrumbs are `.notice`+.
- Read the store (`itunes.apple.com/lookup?id=`) before saying what users have.
- Store copy: name/subtitle are record-wide, so edit `macos/fastlane/metadata_mac`
  AND `metadata_ios` together (`macos/tools/ci/check_store_metadata.py` fails on
  drift). Review notes live only in `macos/fastlane/review_notes.txt`. Run
  `macos/tools/asc/precheck.py` after every deliver push (a stale
  `review_information/notes.txt` clobbered the live notes on 2026-10-01).
  `submit.py --confirm` is Kev's, via `!`.
- Never pre-seed the model cache with `hf download` (cache poison).
- In-app A/B overrides go as argv (`M1K3 -prefillStepSize 512`): on macOS 27
  `defaults write app.m1k3` never reaches the sandboxed app. `log` is a zsh
  builtin — `/usr/bin/log show`. Stop a worktree build by PID, never
  `tell application id "app.m1k3"` (it quits the live app too).
- Speculative decoding of any kind (MTP, DSpark, DFlash, n-gram) loses on
  M1-class GPUs — verifying 2 tokens costs 1.86× one (measured 2026-09-26).
  Re-bench on M4+/M5 before reopening; don't re-run it on M1.
- Mini's window is the device's (`MiniContextWindow`, recorded at launch;
  4,096 is the floor, not the size). Tests never call `record` — a
  source-scan test fails the suite if one does.

<!--
Signed: Kev + claude-fable-5.1, 2026-09-24, Confidence 0.8, Prior: Unknown (the
file carried no signature). Rewritten as the imported standing-facts page:
dropped the `@.claude/project-memory.md` import (~14k tokens of chronicle on
every turn of every session), the graphify section (its graph file has not
existed since June) and the 2026-08-13 orientation banner; distilled the
carry-forwards that recent session blocks kept repeating.
Open: which carry-forwards go stale first — prune at the next /retro.
Review: Kev + claude-fable-5.1, 2026-09-25 — the two landing rules the
macos/CLAUDE.md trim dropped (never merge master in; a test-only unblock
rides the PR) live here now, and "every push builds all three" says
Swift-touching, which is what ci.yml's `swift` filter has always meant.
Confidence 0.8.
Review: Kev + claude-opus-5-5, 2026-09-26 (/debrief) — two standing facts
from #411: summon at once on the first head (folding before summoning
doubled that PR's CI round) + land.sh's never-waits trap; and the one iOS
MLX gate (an A12 iPad trapped warming Kokoro). Confidence 0.85.
Review: Kev + claude-opus-5-5, 2026-09-27 (/debrief) — three standing facts
from the perf sweep (#415/#416/#422): argv not `defaults` for in-app
overrides (+ the zsh `log` and quit-by-bundle-id traps); speculative
decoding is measured dead on M1; Mini's window is the device's.
Confidence 0.85.
Review: Kev + claude-fable-5.1, 2026-09-30 — PR granularity + push/land standing
permission, after Kev asked "are we hurting our zen?": the review loop caught
four real bugs that day and stays; the per-PR ceremony and the human relay
were the cost. Confidence 0.85.
Review: Kev + claude-opus-5-5, 2026-10-01 (/debrief) — store-copy carry-forward
from #463: name/subtitle are record-wide (two metadata folders, one value), the
review notes have one home, and precheck runs after every deliver push (a stale
review_information/notes.txt overwrote the live Mac notes). Confidence 0.9.
-->
