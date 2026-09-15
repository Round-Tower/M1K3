# "Waking Up" — the Golden Gate launch event (in-app event, iPhone + iPad)

The App Store in-app event for M1K3 1.0. Events surface on **iPhone and
iPad only** (Apple's own featuring-nomination form says so; the Mac App
Store has no event surface) — so this is the iOS card, and its real job is
twofold: a second door into the listing from iOS search and the Today tab,
and the **attachment for the featuring nomination** (`../../FEATURING_NOMINATION.md`),
which Apple asks for "as early as possible".

## Copy (`event.json` — en-US below; the other seven locales are in its `localizations` table, every one within cap by test)

| Field | Cap | Text |
|---|---|---|
| name | 30 | Waking Up |
| shortDescription | 50 | A private AI companion, awake on your iPhone. |
| longDescription | 120 | M1K3 is out. Three on-device brains, a neural voice, your notes as memory. No account, no cloud. Private by design. |

Badge **PREMIERE** ("content available for the first time" — a 1.0 is one),
purpose **ATTRACT_NEW_USERS**, priority HIGH, all territories, no deep link
(the app has no URL scheme). Dates: publish 17 Sep, run 18 Sep → 16 Oct
(a 28-day window inside the 31-day cap, promoted from 14 days out). Move
them in `event.json` if approval lands later — Apple rejects an event whose
start has passed.

## Art

Card `event-card-1920x1080.jpg` (16:9) + details `event-details-1080x1920.jpg`
(9:16), JPEG, no text in the art — Apple overlays the event name. Generate
with the Lexy recipe (`dyslexia-ai/ios/marketing/tools/events/gen-event-art.sh`,
gemini-2.5-flash-image styled on a plate, Lanczos to exact size) using an
M1K3 plate as the style reference (`marketing/app-store/plates/ios/chat.png`
or `site/og.png`), the wireframe fox on the dark CRT grid, phosphor green
accents. Art lives OUTSIDE the tree (`marketing/events/waking-up/`,
gitignored) — binaries don't belong in the repo.

## Ship it — there is already a DRAFT on the record; fix it, don't duplicate

`tools/asc/events.py list` (2026-09-15) shows event **6811192045**
"M1K3 Launch — Punk Intelligence Arrives": DRAFT, all eight locales with
card + details art already `COMPLETE` — and every localization over Apple's
caps (en-US short 94/50, long 302/120), badge NEW_SEASON, primary locale
empty, start 15 Sep already past. It cannot be submitted as it stands. The
art is the valuable part; keep it.

```
python3 tools/asc/events.py update --event 6811192045 \
    --spec fastlane/events/waking-up/event.json --dry-run   # payloads only
python3 tools/asc/events.py update --event 6811192045 \
    --spec fastlane/events/waking-up/event.json             # PATCH in place
```

`update` rewrites the attributes (PREMIERE, ATTRACT_NEW_USERS, the dates,
primary locale en-US, all territories) and every localization's copy from
the `localizations` table above, leaving the uploaded art untouched. Writes
to App Store Connect are classifier-blocked from an agent session — Kev
runs it (`!` prefix). `create` stays for a future event with no draft.

Then in App Store Connect: the event → Submit for review (its own queue,
separate from the binary; it locks while in review). Once **approved or
published**, attach it to the featuring nomination.

<!--
Signed: Kev + claude-fable-5.1, 2026-09-15, Confidence 0.8
Format: MurphySig v0.4 (https://murphysig.dev/spec)
Prior: none (new). Copy is within every cap by test; "Private by design" is
  the 1.0 posture (no cloud path ships — ADR 0006's rung is 1.2). The
  iPhone-only surface is Apple's statement, not an inference.
-->
