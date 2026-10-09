# M1K3 — the local AI assistant for Mac (and iPhone / iPad / Vision Pro)

Privacy-focused, on-device AI: MLX inference, live voice, knowledge graph + RAG,
and an MCP server. **The live product is the Mac-native SwiftUI app under
`macos/`** (`M1K3App/`): 1.x on TestFlight and as the Developer ID DMG, submitted to the
Mac App Store (check the store lookup before saying it is live). The same portable
`macos/Sources/` package graph drives the iOS + visionOS shell under
`macos/M1K3iOSApp/`. The legacy Python surface lives only in git history before
`7545b4a4` (`git checkout 7545b4a4 -- attic` resurrects it).

## Start here
- **`macos/CLAUDE.md`** — build, test, architecture, conventions. Read it first.
- **`macos/docs/IOS_VISIONOS_PORT.md`** — the iOS / visionOS shell.
- **`app/CLAUDE.md`** — M1K3 for Android (KMP, slow burn).
- **`CONTRIBUTING.md` / `SECURITY.md`** — the public-repo contributor surface.
- **`.claude/skills/m1k3/README.md`** — the M1K3 mod for Claude Code (loads by itself in
  this checkout): the CLAUDE.md nevers enforced on `tool.call`, M1K3's voice for the moments a
  session needs you, and the avatar band (`/face`, `/companion`).
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
  that head), squash-merges by sha, verifies `state`+`mergedAt`. **One pass is
  the default, whatever the size** (2026-10-04 ruling — PR size is free, rounds
  are the cost): the auto bot pass fires on Swift, the manifest, `project.yml`,
  `macos/tools/**` and the workflows; a docs-only PR gets no auto pass, so summon
  once. Spend the review effort BEFORE the first push (`code-quality-reviewer`
  on the diff, one per ~400-line slice in parallel) and fold every finding in
  ONE push; nits go to the follow-up list in the PR body.
  **Run `pr_watch.py` / `land.sh` without `--passes`: the gate infers it.** It
  asks for 2 (auto + one summon) when the diff touches a risk surface
  (`RISK_SURFACE_PATTERNS` in `pr_watch.py`: agent script execution, MCP /
  Keychain, entitlements, Info.plist, dependencies, privacy and Private Cloud,
  crypto, release/CI config). GRDB migrations live inside `*Store.swift`, so
  they are read off the tree and the patch instead. Also pass `--passes 2`
  yourself when a fold changed logic. Going BELOW the inferred count needs
  `--why "<reason>"` (exit 5 otherwise). For two passes, push then summon AT
  ONCE so both read the same head, and fold both in one commit. Fastlane,
  `.entitlements` and `.xcprivacy` sit outside the auto pass's paths, so there
  "2" means two summons. Trivial head (comment fold, clean master merge on a
  passed head): `--passes 0 --why "trivial head"` on a risk diff, bare
  `--passes 0` otherwise. `land.sh` never waits: pending CI exits 2 and merges
  nothing — run `pr_watch.py <PR>` first.
- **PR granularity (2026-09-30 ruling):** one PR per stream of work per day;
  same-day small fixes ride TOGETHER (a token strip, a scorer check, a tool
  fix, a docs line, a gem bump were five PRs one day — ~12 review rounds and
  six Xcode Cloud archives for one PR's worth of diff). Split only for a
  release gate, an independent revert path, or a change that needs a
  reviewer's whole attention. At most two push-wait-fold rounds per PR (a
  round is a push plus its review, not a pass), then carry the rest to a
  follow-up issue. Claude pushes branches and lands via `land.sh` without
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
  `git rebase --onto` over a squash-merged base. `land.sh` DOES delete the merged
  branch, so retarget dependants first (`gh pr edit <N> --base master`) or GitHub
  closes them (#473 was lost this way, reopened as #474).
- Until #471 ships: a BLE headset in Headset/HFP wedges the voice engine
  (`kAudioUnitErr_TooManyFramesToProcess`, 512 vs 320) even after the route
  returns; MCP `speak` still says "Spoken.". Drain with `stop_speaking`; recovery
  is an app relaunch.
- App Store previews may only be screen captures of the app (guideline 2.3.4) —
  narration + overlays allowed; Mac previews are 1920×1080 only. Pipeline:
  `marketing/motion/PREVIEW-CAPTURE.md`.
- Two MLX processes crawl — quit the live app before an eval run.
- iOS/visionOS MLX has ONE gate, `AppCore.mlxAvailable` (`MLXRuntimeSupport`):
  never on the Simulator or Apple GPU family 5 (A12/A12X/A12Z) — mlx-swift
  traps there, it never throws. Route any new MLX path through it.
- Bundle ID, log subsystem, Keychain and container are all `app.m1k3`.
- `.info` / `.debug` do not persist in OSLogStore; breadcrumbs are `.notice`+.
- Read the store (`itunes.apple.com/lookup?id=`) before saying what users have.
- **Releasing (Mac + iOS on one build):** follow the runbook in `macos/tools/asc/README.md`:
  `builds.py wait` → install N from TestFlight and **relaunch** M1K3 → `verify_build.py --build N`
  → `submit.py cancel/attach/submit --platform ALL --confirm`. **Verify before any cancel**: a
  cancel loses the queue spot (2026-10-05: both were cancelled before the build was checked).
  `submit` refuses an unstamped build unless `--why`. Relaunching matters until #491, because the
  stale-process check reads the binary's mtime, which installers preserve. ASC writes are Kev's, via `!`.
- Store copy: name/subtitle are record-wide, so edit `macos/fastlane/metadata_mac`
  AND `metadata_ios` together (`macos/tools/ci/check_store_metadata.py` fails on
  drift). Review notes live only in `macos/fastlane/review_notes.txt`. Run
  `macos/tools/asc/precheck.py` after every deliver push (a stale
  `review_information/notes.txt` clobbered the live notes on 2026-10-01).
  `submit.py --confirm` is Kev's, via `!`.
- Store creative (iOS 27 header + search, iPhone/iPad only): render with
  `macos/tools/site/store_creative.py` (`--check` is the gate), then
  `macos/tools/asc/creative.py upload|place` (dry-run until `--confirm`, Kev's
  via `!`). A placement needs an editable version, CPP or PPO; never cancel a
  review to place art.
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
- Verify-by-launch with a Debug build: `open -n --env M1K3_SCREENGRAB=1 --env
  M1K3_SCREENGRAB_PLATE=<plate> --env M1K3_SCREENGRAB_RUN=<token> <app>` (an
  isolated store; the window is pinned at 1440×900). Never exec the binary from
  a shell: it isn't foreground, so system sheets (Declared Age Range) dismiss
  and the API says `notAvailable`. No coordinate clicks while Kev is active.
- Entitlements by lane: Declared Age Range in all three (`M1K3-MAS`, `M1K3iOS`
  and the Developer ID `M1K3.entitlements`; `check_store_targets.py` requires
  it), PCC in `M1K3-MAS.entitlements` only (the check forbids it in the
  Developer ID lane, whose profile lacks it: AMFI would kill the launch). The
  Developer ID lane embeds a profile since #518: macOS 27 sends every keychain
  call to the data-protection keychain, so a profile-less build can store
  nothing (-34018, no MCP server). CI's manual signing needs the portal profile
  "M1K3" (secret `MACOS_DEVELOPER_ID_PROFILE`); Xcode's managed one is refused
  there. PCC consent is
  `PrivateCloudArming` (ADR 0010: asked once, by message id): any new path that
  sends history to PCC goes through it.

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
Review: Kev + claude-opus-5-5, 2026-10-04 — the landing loop goes from size
tiers (two passes on anything substantive) to one pass by default, two only
for a risk surface or a logic-changing fold; `pr_watch.py --passes` now
defaults to 1. Kev: dev here had slowed under the two-pass loop. Kept from
2026-09-30: two rounds per PR, then carry. Confidence 0.75 — the 09-30 entry
says the loop caught four real bugs in a day, and nobody has measured how
many of those only the second pass found.
Review: Kev + claude-opus-5-5, 2026-10-04 (2) — the Open above is closed. The
audit of 132 merged PRs (#287–#480, final pass vs earlier passes, classified by
an offload model and spot-checked by hand) found 33 real catches only a later
pass made: 28 came after a fold (re-reviewed by that head's auto pass anyway),
17 sit on risk surfaces, and 2 would be lost outright (#292 marquee offset,
#320 latent persona hazard). So pr_watch now infers the passes from the diff
(47% of history would get 2, down from 89%), and a downgrade needs `--why`.
The challenger caught that migrations hide in *Store.swift. Confidence 0.8.
Review: Kev + claude-opus-5-5, 2026-10-01 (/debrief, #462) — the Debug-launch
recipe (an exec'd binary isn't foreground: the age sheet dismissed itself) and
the entitlement + PCC-consent seams. Confidence 0.85. Fold 2026-10-05: PCC is
in the Mac store lane only; the check requires only Declared Age Range there.
Review: Kev + claude-opus-5-5, 2026-10-05 (/debrief) — the release carry-forward:
the asc runbook from #490, verify before cancel, and relaunch until #491. 1.0.0 went to
review on build 453. Confidence 0.85.
Review: Kev + claude-opus-5-5, 2026-10-07 (/debrief) — store-creative carry-forward
from #506: where the header/search generator and the Asset Library uploader live,
and that a placement waits for an editable surface. Confidence 0.85.
Review: Kev + claude-opus-5-5, 2026-10-09 — entitlements by lane after #518: the Developer ID
lane embeds a profile (macOS 27's keychain), so Declared Age Range is in all three lanes and
PCC stays MAS-only. Confidence 0.85 (keychain verified by launch; the age sheet owed by Kev).
-->
