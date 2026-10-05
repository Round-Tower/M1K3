# `tools/asc` — App Store Connect scripts for the app.m1k3 record

The durable home for the listing scripts. The launch-day ones (keywords,
pricing, submit) lived in a session scratchpad and died with it; that is
the failure this directory exists to end (`.claude/project-memory.md`,
2026-09-15 reflection).

Auth: `asc.py` signs an ES256 JWT from `~/.appstoreconnect/private_keys/asc_api_key.json`
(the fastlane JSON the Fastfile reads), or from `ASC_KEY_ID` +
`ASC_KEY_ISSUER_ID` with `AuthKey_<id>.p8` beside it. Needs `PyJWT` and
`requests` at run time; pytest needs neither. The release scripts (`submit.py`,
`precheck.py`, `builds.py`) carry a PEP 723 header, so `./submit.py status`
runs through `uv` with its own deps. No `--with` incantation, no Intel-Python trap.

## Release runbook (Mac + iOS on one build)

Verify before you cancel: once a submission is cancelled, its place in the queue is gone.

```
./builds.py wait                                      # origin/master's build is VALID on Mac + iOS → N
# install build N from TestFlight on this Mac, launch M1K3
./verify_build.py --build N                           # running app is N and answers MCP → stamps N
./submit.py cancel --platform ALL --confirm --wait    # only if a submission is live
./submit.py attach --platform ALL --build N --confirm
./precheck.py --platform MAC_OS; ./precheck.py --platform IOS
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

| Script | What it does | Writes? |
|---|---|---|
| `precheck.py` | The pre-submit checklist: build attached + VALID, screenshots per display type, availability (V2), price schedule, keyword trademarks, promo cap, support URL. | no |
| `keywords.py scan` / `apply` | Trademark + cap scan of name, subtitle and keywords on every platform's newest version; `apply` PATCHes one localization. Keywords LOCK while in review. | apply only |
| `submit.py status` / `submit` / `cancel` / `attach` | Review submissions per platform, or `--platform ALL` (Mac + iOS): create → add the newest version → `submitted:true`; a queued one is nothing to do; `cancel` is `canceled:true` (the queue position is the price), and `--wait` holds until the version is editable; `attach --build N` puts a VALID build with export compliance answered on an editable version and reads it back. `submit --confirm` refuses a build `verify_build.py` hasn't stamped, unless `--why`. | submit / cancel / attach + `--confirm` |
| `builds.py wait` / `status` | Which Xcode Cloud run built a commit (default `origin/master`), then wait for its Mac + iOS builds to process VALID. A CANCELED run means a later run carries the commit. | no |
| `verify_build.py --build N` | The installed `/Applications/M1K3.app` is build N, it is running, and its MCP server answers `initialize` with instructions; stamps N for `submit`. Reads the MCP token in-process, never prints it. | a local stamp only |
| `review_notes.py show` / `set` | App Review Information notes on every platform's newest version, checked against `fastlane/review_notes.txt`'s rule: both inbound listeners (MCP server, Brain at Home) must be named — the 2026-09-16 `network.server` rejection. `precheck.py` runs the same check. | set + `--confirm` |
| `promo.py show` / `set` | Promotional text (170 chars) — the one field that goes live without a build. | set + `--confirm` |
| `events.py list` / `create` / `update` | In-app events (iPhone/iPad only): a DRAFT from a spec file (copy + art), or an in-place rewrite of an existing DRAFT's attributes and per-locale copy keeping its art. Never submits. | create / update (`--dry-run` to see payloads) |
| `testflight.py show` / `set` | The beta app description — one text every platform's testers read (betaAppLocalizations), from `TestFlight/beta_description.en-US.txt`; refuses text that doesn't name iPhone, iPad and Mac. Per-build "What to Test" is Xcode Cloud's (`TestFlight/notes/`). | set + `--confirm` |

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
-->

Tests: one `test_<tool>.py` per tool with pure logic to pin (`promo.py` has none — every function is a request; the global pre-commit hook's rule for new source files; the shared `test_asc_tools.py` was split on 2026-09-16). CI runs `pytest tools/asc`.
