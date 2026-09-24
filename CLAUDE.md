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
- `.mcp.json` points at the Mac app's in-app MCP server (`127.0.0.1:4242/mcp`).

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
  reviews the head at RUN time — push first, then summon. Same-day small fixes
  ride one PR unless a release gate needs them apart.
- **CI on a PR:** package-only diffs are gated by `swift test` (~4 min); the
  App-shell and iOS+visionOS xcodebuild jobs run only when their paths change
  (the `shell` / `mobile` filters in `ci.yml`). Every push to master or develop
  builds all three — a shell break lands, then is fixed forward.
- `xcodegen` after every checkout; `M1K3.xcodeproj` is a gitignored artifact.
- A worktree `xcodebuild` needs `-skipPackagePluginValidation -skipMacroValidation`.
- `swift package clean` before protocol/struct-shape changes (segfault, 3+ hits).
- swiftformat's unused-parameter rename runs BETWEEN batched edits: change a
  signature and its call sites in ONE edit, re-read before the next.
- Merge stacked PRs bottom-up; never `--delete-branch` on a stack base;
  `git rebase --onto` over a squash-merged base.
- Two MLX processes crawl — quit the live app before an eval run.
- Bundle ID, log subsystem, Keychain and container are all `app.m1k3`.
- `.info` / `.debug` do not persist in OSLogStore; breadcrumbs are `.notice`+.
- Read the store (`itunes.apple.com/lookup?id=`) before saying what users have.
- Never pre-seed the model cache with `hf download` (cache poison).

<!--
Signed: Kev + claude-fable-5.1, 2026-09-24, Confidence 0.8, Prior: Unknown (the
file carried no signature). Rewritten as the imported standing-facts page:
dropped the `@.claude/project-memory.md` import (~14k tokens of chronicle on
every turn of every session), the graphify section (its graph file has not
existed since June) and the 2026-08-13 orientation banner; distilled the
carry-forwards that recent session blocks kept repeating.
Open: which carry-forwards go stale first — prune at the next /retro.
-->
