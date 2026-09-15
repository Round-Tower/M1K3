# `tools/asc` — App Store Connect scripts for the app.m1k3 record

The durable home for the listing scripts. The launch-day ones (keywords,
pricing, submit) lived in a session scratchpad and died with it; that is
the failure this directory exists to end (`.claude/project-memory.md`,
2026-09-15 reflection).

Auth: `asc.py` signs an ES256 JWT from `~/.appstoreconnect/private_keys/asc_api_key.json`
(the fastlane JSON the Fastfile reads), or from `ASC_KEY_ID` +
`ASC_KEY_ISSUER_ID` with `AuthKey_<id>.p8` beside it. Needs `PyJWT` and
`requests` at run time; pytest needs neither.

| Script | What it does | Writes? |
|---|---|---|
| `precheck.py` | The pre-submit checklist: build attached + VALID, screenshots per display type, availability (V2), price schedule, keyword trademarks, promo cap, support URL. | no |
| `keywords.py scan` / `apply` | Trademark + cap scan of name, subtitle and keywords on every platform's newest version; `apply` PATCHes one localization. Keywords LOCK while in review. | apply only |
| `promo.py show` / `set` | Promotional text (170 chars) — the one field that goes live without a build. | set + `--confirm` |
| `events.py list` / `create` / `update` | In-app events (iPhone/iPad only): a DRAFT from a spec file (copy + art), or an in-place rewrite of an existing DRAFT's attributes and per-locale copy keeping its art. Never submits. | create / update (`--dry-run` to see payloads) |

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
