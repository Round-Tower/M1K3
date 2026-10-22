# "Offline AI Flight Club": the November 2026 event (in-app event, iPhone + iPad)

From **Nov 3 to Dec 1 (the device's local calendar)**, **while the device is offline**,
M1K3 wears a flight look: the companion switches to the flight phosphor palette (ice-white
at rest, beacon amber while speaking, instrument cyan while thinking, pale gold while
listening) and the greeting card says "Offline? I'm still right here, on your device."
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

## Art: TODO, not made yet

Nothing in this section exists yet. Both slots need media before `create` can run for
real:

| File | Slot | Format |
|---|---|---|
| `event-card-1920x1080.jpg` (or `.mp4`) | Event card, 16:9 | 1920×1080 sRGB still, or H.264 30/60 fps video per Apple's table |
| `event-details-1080x1920.jpg` (or `.mp4`) | Details page, 9:16 | 1080×1920, the same |

The plan is stills taken from the app itself: a Mac Debug build launched with
`-seasonalLook flightclub`, which forces the look on whatever the date and the network,
using the verify-by-launch harness (`open -n --env M1K3_SCREENGRAB=1 …`; see the repo
CLAUDE.md), cropped to each slot, textless. The art lives beside Halloween's, in
`../marketing/events/flight-club`. The rules Halloween's README records still apply: no
text or logos in the art, no borders or gradients, keep the fox in the upper-centre 60%
with the bottom third quiet, and check the media in App Store Connect's event preview
before submitting. The palette, colour for colour, is the app's flight palette in
`PhosphorTreatment.swift`: ICE WHITE `#E8F4FF`, BEACON AMBER `#FFB000`, INSTRUMENT CYAN
`#3FD0FF`, PALE GOLD `#FFE2A8`. `event_art.py` has no `flightclub` palette; adding one is
a follow-up if a 2D fallback is wanted.

The flight look itself hasn't been seen on screen yet (the Flight Club implementation
notes say so), so the first stills are also its first visual check.

## Ship it (ASC writes are Kev's, via `!`)

```
python3 tools/asc/events.py create --spec fastlane/events/flight-club/event.json \
    --art-dir ../marketing/events/flight-club --dry-run   # payloads only, no key needed
python3 tools/asc/events.py create --spec fastlane/events/flight-club/event.json \
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
  locales). Open: a native read of the eleven non-English locales; the art (none made);
  whether ATTRACT_NEW_USERS is honest given the first-session hello; 1.2.1 live on the iOS
  store before 1 Nov 12:00Z; the flight look seen on a device in real Airplane Mode.
-->
