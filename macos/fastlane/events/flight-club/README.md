# "Offline AI Flight Club": the November 2026 event (in-app event, iPhone + iPad)

From **Nov 3 to Dec 1 (the device's local calendar)**, **while the device is offline**,
M1K3 wears a flight look: the companion switches to the night-flight phosphor palette
(runway blue at rest, beacon amber while speaking, strobe white while thinking, nav green
while listening) and the greeting card says "Offline? I'm still right here, on your device."
(It promises presence, not answers: offline with no brain downloaded, M1K3 can't answer.) Back online, the look and the line go away. That is everything the event is: a
look and a greeting, gated on dates and on having no network. There's an opt-out in
Settings ("Seasonal looks", the same one Halloween uses), and nothing leaves the device.
The copy promises exactly that and no more: no costume, no goggles, no gear. Events show
on **iPhone and iPad only** (see `../waking-up/README.md`).

What "offline" means in the app: `NetworkPathWatch` (M1K3Avatar) reads `NWPathMonitor`,
and only `.unsatisfied` counts. Airplane Mode with Wi-Fi off is offline. Airplane Mode
with in-flight Wi-Fi switched back on is online, even behind a captive portal, so that
passenger sees the normal look. The copy says "turn on Airplane Mode" because that's the
one switch everyone knows. A full read of the logic is in `Sources/M1K3Avatar/SeasonalLook.swift`.

**Gate:** the build that carries the flight look (1.2.1) must be live on the iOS App Store
before this event publishes (1 Nov 12:00 UTC). Read the store lookup
(`itunes.apple.com/lookup?id=6780230835`) before submitting the event. On 2026-10-22 it
said **1.2.0** (released 2026-10-21), which has no flight look. An event card for a look
users can't get breaks the one promise it makes. If 1.2.1 isn't live in time, move
`publishStart` (and, if needed, `eventStart`) rather than publish ahead of the build.

## Copy (`event.json`; en-US below, the other eleven locales in its `localizations` table, all within the caps by test)

| Field | Cap | Text |
|---|---|---|
| name | 30 | Offline AI Flight Club (22) |
| shortDescription | 50 | Airplane Mode on. Your AI keeps answering. (42) |
| longDescription | 120 | From Nov 3 to Dec 1, turn on Airplane Mode: the Phosphor Fox wears its flight colors, says hello and keeps answering. (117) |

Counts are Python `len`, the same measure `events.py` and its tests use.

"Airplane Mode" is Apple's own term for the switch in each language, so a reader can find
it in Settings: Aeroplane Mode (en-GB), Flugmodus, modo Avión (es-ES and es-MX), mode Avion,
機内モード, 에어플레인 모드 (Apple's Korean; 비행기 탑승 모드 is another vendor's), modo Avião,
飞行模式, Авиарежим, وضع الطيران. The fox keeps the local names Halloween used
(Phosphorfuchs, zorro fosforescente, renard phosphorescent, 燐光のキツネ, 인광 여우, raposa
fosforescente, 磷光狐狸, Фосфорный лис); ar-SA keeps "Phosphor Fox" in Latin script and,
like Halloween's, never addresses the reader in the second person, so it stays
gender-neutral. Address follows each listing: du (de), tú (es), vous (fr), você (pt-BR),
ты (ru). es-MX reuses es-ES, as Halloween's does. These are drafts by the model and
haven't had a native read.

- **Badge `SPECIAL_EVENT`.** Apple: "Limited-time events that aren't captured by another
  event badge … These events should provide users with new content, features, or goods."
  A seasonal look fits no other badge. The same caveat as Halloween holds: Apple may judge
  a cosmetic look thin. If review pushes back, the honest answer is the look, the greeting
  and the dates, plus the thing the event is really about: M1K3 answers with no network.
- **Purpose `APPROPRIATE_FOR_ALL_USERS`** (decided 2026-10-22, was `ATTRACT_NEW_USERS` in the
  draft). `GreetingCard` hides the seasonal line during first-session onboarding, so a
  brand-new user who installs from the card sees the flight colours but not the hello until
  they come back. "Says hello" is only fully true for returning users; pitching the card at
  new users would lean on the half that isn't. Same purpose as Halloween.
- **Priority NORMAL**, no purchase, all territories.
- **Deep link `m1k3://event/offline-ai-flight-club`.** `DeepLink` (M1K3Inference) reads any
  `m1k3://event/<name>` and opens chat, so no new parsing was needed; `DeepLinkTests`
  pins this exact link, hyphens and all. The task brief suggested `event/flight-club`;
  this spec uses the name the Swift test pins, so the two can't drift. Either parses.
  The honest limit: a user can only tap the card while online, so the link always lands on
  the normal look. That's why the copy tells them what to do next (turn on Airplane Mode).
- **Dates (UTC):** publish 1 Nov 12:00 (after Halloween's card ends at 1 Nov 11:00, and
  1 day 22 h before the start; the cap is 14 days), run 3 Nov 10:00 → 1 Dec 11:00
  (28 days 1 h; the cap is 31).

### UTC times inside every local window

The look can run 3 Nov 00:00 to 1 Dec 23:59:59 on each device's local calendar
(`SeasonalLook.active`, offline only), but an event's times are single UTC instants. As
for Halloween, `eventStart` is local midnight on 3 Nov in UTC−10 (Hawaii), later
everywhere east, and `eventEnd` is local midnight on 2 Dec in UTC+13 (New Zealand
daylight time, in force through December), earlier everywhere west:

| | Local | UTC |
|---|---|---|
| eventStart | 3 Nov 00:00 in UTC−10 | 2026-11-03T10:00:00Z |
| eventEnd | 2 Dec 00:00 in UTC+13 | 2026-12-01T11:00:00Z |

From UTC−10 to UTC+13 the card is never live on a date the look can't show. The price is
a card up to 23 hours shorter than the look at each end. The span is 28 days 1 hour, under
Apple's 31-day cap, so the card's end needed no further cut. Halloween's look ends 1 Nov
and this one starts 3 Nov, so the two never overlap on any device, and the cards don't
either (Halloween's ends 1 Nov 11:00Z, this one publishes an hour later).

## Art: the Phosphor Fox in its flight colours, taken from the app

| File | Slot | Format |
|---|---|---|
| `event-card-1920x1080.jpg` | Event card, 16:9 | 1920×1080 JPEG, quality 90, sRGB-tagged, 359 KB |
| `event-details-1080x1920.jpg` | Details page, 9:16 | 1080×1920, the same, 368 KB |

Both slots are stills, with no video yet. They show the real app in the flight look at rest:
the site Fox's black triangles under a RUNWAY BLUE lattice, on the voice-mode hero's glass
with its CRT scanlines. Nothing is drawn on top, so there's no text, logo, border or gradient.
The fox is in the upper part of each frame and the bottom 40% is empty backdrop (card: fox
723×516 at y 108–624; details: 855×609 at y 384–993). The `*-guides.png` proofs mark the
safe area (the same third-party read as Halloween's: top 5% on the card or 8% on the
details page, bottom 40%, sides 6%), and the fox sits inside it on both. Like Halloween's,
the safe area is UNVERIFIED until App Store Connect's event preview shows the media.

How they were made (2026-10-28, a Mac Debug build of master `5d2e70a2`; the fox's paint and
palette haven't changed since `release-1.2.1-20261023-e4ce9115`, the build on the store):

- **Launch.** The build ran under the screengrab harness on the `companion-fox` plate, which
  opens voice mode with the house face. The flight look was forced on:
  `open -n --env M1K3_SCREENGRAB=1 --env M1K3_SCREENGRAB_PLATE=companion-fox … M1K3.app --args
  <the plate recipe> -selectedBrain mini -seasonalLook flightclub`. Mini kept a second MLX
  brain out of memory beside the live app. No chat turn was sent.
- **Glass.** The hero sits on the window's behind-window glass, so its backdrop is whatever is
  behind the window. `screencapture -l` renders the window alone, and the glass comes out
  flat grey (70/255). So a borderless black window went directly behind the app window,
  which makes the glass as dark as it gets (39/255). Then the window's rectangle was
  region-captured (`screencapture -R`) 40 times, a second apart.
- **Frame.** Frame 32 has the head turned to the viewer and the tail out, and it lies outside
  the CRT roll band's sweep.
- **Compose.** The frame went from Display P3 to sRGB with `sips --matchTo`, then through
  the art dir's source/compose.py (git-ignored, beside the stills). The backdrop has one colour per row and a dark scanline every 16 px,
  so the canvas is the frame's own 16-row period, tiled. The fox's rectangle is pasted in on
  the same scanline phase; the seam measures 0. The whole canvas is then scaled down once:
  ×0.6875 for the card (11 px scanlines) and ×0.8125 for the details page (13 px).
- **Reproduce.** `source/voice-hero-flightclub-rest-srgb-crop.png` is that frame's clean band
  (2520×1250). It rebuilds both stills bit for bit:
  `uv run --with pillow --with numpy python source/compose.py source/voice-hero-flightclub-rest-srgb-crop.png <out> --rows 0,1250 --cols 0,2520`,
  then `sips -s format jpeg -s formatOptions 90 --embedProfile "/System/Library/ColorSync/Profiles/sRGB Profile.icc"`.

`python3 tools/site/event_art.py --check --out ../marketing/events/flight-club` passes both
stills. `event_art.py` still has no `flightclub` palette; the 2D fallback wasn't needed.

**The palette is the code's** (`PhosphorTreatment.swift`, pinned by
`SeasonalLookTests.flightPalette`):

- RUNWAY BLUE `#4A86FF` at rest
- BEACON AMBER `#FFB000` while speaking
- STROBE WHITE `#F4F8FF` while thinking
- NAV GREEN `#39FF7A` while listening

The first draft of this README named TAXIWAY BLUE `#2A5CFF` for the rest colour. #669
replaced it before merging, because it was too dark for a lattice line on black: relative
luminance 0.37, under `SiteFoxPaintTests`' 0.45 floor, where runway blue scores 0.51. On
screen, the unlit lattice renders a little darker than its value. The resting lattice
measures about `#3A74D7` in the sRGB capture. That's a measurement, not a spec.

**First sight on a Mac (2026-10-28).** Before this, the look had only been seen on the iPhone
Simulator (#669).

- **Rest (runway blue).** It reads cleanly. The black silhouette carries the shape, and the
  lattice stays visible when the card is shrunk to phone width.
- **Listening (nav green).** Seen after a mute and restart. It's close to the house default
  mint, so to a casual eye a listening fox looks like the normal look, not "flight".
- **Thinking and speaking.** Not seen: both need a chat turn.
- **Defect.** On entering voice mode, the fox kept its rest colour while the caption said
  "Listening…". It turned nav green only after the loop was muted and restarted. Likely
  cause: `VoiceModeView.swift:121`, `.onChange(of: env.voiceLoop?.state)` has no
  `initial: true`, so a loop that is already listening when the hero mounts never sets
  `.listening` on the avatar. That was seen under the harness's open mic, which starts at
  once. Whether a real microphone start races the same way is UNVERIFIED. The bug isn't
  specific to Flight Club.

## Ship it (ASC writes are Kev's, via `!`)

```
./tools/asc/events.py create --spec fastlane/events/flight-club/event.json \
    --art-dir ../marketing/events/flight-club --dry-run   # payloads only, no key needed
./tools/asc/events.py create --spec fastlane/events/flight-club/event.json \
    --art-dir ../marketing/events/flight-club             # the DRAFT, 12 locales, art on each
```

If `create` fails part-way, the error ends with the `create … --event <id>` line that
resumes it; a plain re-run would make a second event. Before review, paste
`m1k3://event/offline-ai-flight-club` into Notes on an iPhone running 1.2.1 and tap it:
M1K3 should open on chat. Then switch on Airplane Mode and look for the flight colours
and the line. Add the event's paragraph to `fastlane/review_notes.txt` (how App Review
sees the look before 3 Nov: Airplane Mode won't do it, the dates gate it too, so point
them at a TestFlight build or the screenshots). Events have their own review queue and
lock while in review, and the start can't have passed when Apple approves it.

<!--
Signed: Kev + claude-opus-5-5, 2026-10-22, Confidence 0.7
Format: MurphySig v0.4 (https://murphysig.dev/spec)
Prior: none (new file). Modelled on ../halloween/README.md and its event.json. The copy is
  within every cap by test (tools/asc/test_events.py pins the window, the link and the
  locales). Open: a native read of the eleven non-English locales;
  whether ATTRACT_NEW_USERS is honest given the first-session hello; the flight look seen on a
  device in real Airplane Mode.
Review: Kev + claude-opus-5.5, 2026-10-28 — the art exists: two textless stills of the app itself (Mac Debug,
  -seasonalLook flightclub, the voice-mode hero on glass over a black backing), composed on the scanline phase,
  spec-checked, and `events.py create --dry-run` passes with them. The palette line follows the code (RUNWAY
  BLUE #4A86FF; taxiway #2A5CFF was the pre-#669 draft), and Ship it runs the script through its uv shebang
  (system python3 has no jwt). Retires the "art (none made)" Open, and "1.2.1 live on the iOS store" (store
  lookup 2026-10-28: released 10-23, and its tag carries #669). Still open: ASC's event preview of the stills
  under the overlays, and the voice hero's first-listen colour (VoiceModeView `onChange` without `initial:`).
  Kev's call 10-28: run the event. Confidence 0.75
-->
