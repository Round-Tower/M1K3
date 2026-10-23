# `tools/asc` — App Store Connect scripts for the app.m1k3 record

The durable home for the listing scripts. The launch-day ones (keywords,
pricing, submit) lived in a session scratchpad and died with it; that is
the failure this directory exists to end (`.claude/project-memory.md`,
2026-09-15 reflection).

Auth: `asc.py` signs an ES256 JWT from `~/.appstoreconnect/private_keys/asc_api_key.json`
(the fastlane JSON the Fastfile reads), or from `ASC_KEY_ID` +
`ASC_KEY_ISSUER_ID` with `AuthKey_<id>.p8` beside it. Needs `PyJWT` and
`requests` at run time; pytest needs neither. Every script that calls the API carries a PEP 723
header (`test_asc.py` fails on one without), so `./submit.py status` runs through `uv` with its
own deps. No `--with` incantation, no Intel-Python trap.

## Release runbook (Mac + iOS on one build)

Verify before you cancel: once a submission is cancelled, its place in the queue is gone.

Xcode Cloud starts **only on `release*` tags** (2026-10-17: building every master push spent the
month's compute hours by the 15th). Merging to master builds nothing; cutting a release does:

```
./release_tag.py cut                                  # dry run: the tag it would push, and CI on that commit
./release_tag.py cut --confirm                        # Kev's call: tags origin/master (green CI) and pushes → a build starts
                                                      # (the tag's day is UTC; an older, superseded master commit
                                                      #  reads CI `cancelled` and needs --why)
./builds.py wait                                      # the newest release tag's build is VALID on Mac + iOS → N
# Xcode Cloud out of compute (the run CANCELED seconds after creation, no reason)? Build it here
# with N = the cancelled run's number: ../release/release-local.sh N, Kev runs the
# upload-local.zsh line it prints, then ./testflight.py notes --build N --confirm (a local
# upload has no What to Test). Then carry on below.
# install build N from TestFlight on this Mac, launch M1K3
./verify_build.py --build N                           # running app is N and answers MCP → stamps N
./submit.py cancel --platform ALL --confirm --wait    # only if a submission is live
./submit.py attach --platform ALL --build N --confirm
./precheck.py --platform MAC_OS; ./precheck.py --platform IOS
# an in-app event riding the release: ./events.py create --spec … --art-dir …, then App Store Connect ▸
# In-App Events ▸ the event ▸ Add for Review (a draft with NO platform); `status` lists it under IOS and
# submit adopts it, adds the version and sends both (#605; the API path is unproven: dry-run first)
./submit.py submit --platform ALL --confirm           # refuses an unstamped build (exit 5) unless --why
```

`submit --platform ALL --confirm` is two-phase: it checks every platform's whole plan first
(gate, CANCELING, version state, build VALID + export compliance) and sends nothing unless all
pass; then it stages all, then sends all, and names any platform a failed send left behind.
`attach --platform ALL` is different on purpose: one PATCH per platform, so it carries on after a
failure and returns the worst exit code. A stamp is a JSON file naming its build; it never
expires, because build numbers never repeat. The stamp comes from the Mac run; iOS ships the same build number from the
same source, but the iPhone app itself is checked by hand on a device.
The stamp proves only that build N runs and serves MCP. Feature checks (a fix's repro, the
voice on a headset) are still yours to run, and the PR that made the change names them.

**A brain re-pinned with `pin_weights.py --snapshot-root` owes one more check.** Those bytes came
from a fresh HF download, so HF's oid check only proves the download matches HF, not that it is
the copy that was run and evaluated; the second opinion is build N verifying that evaluated copy. Before submitting, load that brain once
in build N and read `/usr/bin/log show --predicate 'subsystem == "app.m1k3" AND category == "weight-integrity"'`
for `verified <repo> against pinned revision …` (a refusal there means the pin and the evaluated
bytes disagree: stop). Lil's 2026-10-08 pin (#517) took this route and passed on a local build.

| Script | What it does | Writes? |
|---|---|---|
| `precheck.py` | The pre-submit checklist: build attached + VALID, screenshots per display type, availability (V2), price schedule, keyword trademarks, promo cap, support URL. | no |
| `keywords.py scan` / `apply` | Trademark + cap scan of name, subtitle and keywords on every platform's newest version; `apply` PATCHes one localization. Keywords LOCK while in review. | apply only |
| `submit.py status` / `submit` / `cancel` / `attach` | Review submissions per platform, or `--platform ALL` (Mac + iOS): create → add the newest version → `submitted:true`; a queued one is nothing to do; `cancel` is `canceled:true` (the queue position is the price), and `--wait` holds until the version is editable; `attach --build N` puts a VALID build with export compliance answered on an editable version and reads it back. `submit --confirm` refuses a build `verify_build.py` hasn't stamped, unless `--why`. | submit / cancel / attach + `--confirm` |
| `release_tag.py cut` / `list` | Tags a commit on origin/master whose GitHub CI passed as `release-<version>-<yyyymmdd>-<sha8>` and pushes it: the only thing that starts an Xcode Cloud build. Dry run unless `--confirm`; refuses off-master commits (exit 3) and a red or unfinished CI (exit 4) unless `--why`; a commit already tagged is left alone. | `--confirm` only (a git tag) |
| `builds.py wait` / `status` | Which Xcode Cloud run built a commit (default: the newest release tag's), then wait for its Mac + iOS builds to process VALID. A commit no release tag points at stops at once (exit 4) with the `cut` command. A CANCELED run means a later run carries the commit. | no |
| `verify_build.py --build N` | The installed `/Applications/M1K3.app` is build N, it is running, and its MCP server answers `initialize` with instructions; stamps N for `submit`. Reads the MCP token in-process, never prints it. | a local stamp only |
| `review_notes.py show` / `set` | App Review Information notes on every platform's newest version, checked against `fastlane/review_notes.txt`'s rule: both inbound listeners (MCP server, Brain at Home) must be named — the 2026-09-16 `network.server` rejection. `precheck.py` runs the same check. | set + `--confirm` |
| `promo.py show` / `set` | Promotional text (170 chars) — the one field that goes live without a build. | set + `--confirm` |
| `events.py list` / `create` / `update` | In-app events (iPhone/iPad only): a DRAFT from a spec file (copy + art), or an in-place rewrite of an existing DRAFT's attributes and per-locale copy keeping its art. Never submits. | create / update (`--dry-run` to see payloads) |
| `creative.py status` / `targets` / `upload` / `place` | Product page header + search results assets (iOS 27, App Asset Library): upload once (reserve → PUT → `{uploaded:true}` → poll), place per localization on a version, custom product page or PPO treatment. Checks ASC's chosen spec against the live catalogue and refuses a parent that isn't editable. Renders come from `tools/site/store_creative.py`. | upload / place + `--confirm` |
| `testflight.py show` / `set` / `notes` | The beta app description — one text every platform's testers read (betaAppLocalizations), from `TestFlight/beta_description.en-US.txt`; refuses text that doesn't name iPhone, iPad and Mac. `notes --build N` writes build N's "What to Test" on Mac + iOS from `TestFlight/notes/` and reads it back: Xcode Cloud copies those itself, a local upload arrives without them. | set / notes + `--confirm` |
| `metrics.py store` / `analytics request` / `analytics list` / `analytics fetch` / `repo` | Reach without telemetry. `store`: App Store units per day from the daily sales reports, filtered to this app (the report is vendor-wide), split downloads / updates by platform and country; needs `ASC_VENDOR_NUMBER`. `analytics`: the standing ONGOING report request Apple needs, then list and fetch its daily CSVs (impressions, product page views, conversion, sources). `repo`: GitHub stars, forks, DMG downloads per release, 14-day traffic and referrers, appended to `marketing/metrics/repo.jsonl` because GitHub forgets traffic after 14 days. | `analytics request` (one standing request) |
| `ranks.py [terms…] [--country …] [--platform ios,mac] [--vs DATE]` | Search rank per term × storefront × platform from the public iTunes Search API (no key, top 200), with movement against the previous run, or the newest run on or before `--vs` for a keyword change's before/after. Terms live in `rank_terms.txt`; the default storefronts are the ad countries plus KZ/UZ/IN, where organic iOS search comes from. The API's order is a proxy for the store's: trust the trend, not the slot. | appends to `marketing/metrics/ranks.jsonl` (`--no-log` to just look) |

```
python3 tools/asc/precheck.py
python3 tools/asc/keywords.py scan
python3 tools/asc/events.py create --spec fastlane/events/waking-up/event.json \
    --art-dir ../marketing/events/waking-up --dry-run
python3 -m pytest -q tools/asc
```

Not readable by API, so never claimed: the App Privacy label (confirm
"Data Not Collected" is PUBLISHED in ASC) and featuring nominations (ASC UI
only — the paste-ready text is `fastlane/FEATURING_NOMINATION.md`).

<!--
Signed: Kev + claude-fable-5.1, 2026-09-15, Confidence 0.85
Format: MurphySig v0.4 (https://murphysig.dev/spec)
Prior: none (new directory). The Lexy tools this ports are credited per file.
Review: Kev + claude-opus-5-5, 2026-10-17 — `release_tag.py` and the runbook's first step: Xcode Cloud builds only
`release*` tags now, and `builds.py wait` defaults to the newest one. Confidence 0.85.
Review: Kev + claude-fable-5.1, 2026-10-20 — `metrics.py`: reach read from the counters that already exist (sales
reports, the Analytics Reports API, GitHub) instead of telemetry the app will never send. The first live run
counted every Round Tower app: the sales report is vendor-wide, so rows are filtered to the Apple Identifier.
Confidence 0.8.
Review: Kev + claude-opus-5.5, 2026-10-23 — `ranks.py`: rank tracking across storefronts in our own tooling instead of
a paid ASO app (Sextant was weighed and covers iOS only). Confidence 0.75: the Search API's order approximates the store's.
-->

Tests: one `test_<tool>.py` per tool with pure logic to pin (`promo.py` has none — every function is a request; the global pre-commit hook's rule for new source files; the shared `test_asc_tools.py` was split on 2026-09-16). CI runs `pytest tools/asc`.
