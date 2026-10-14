# "Halloween in the Lair": the 2026 seasonal event (in-app event, iPhone + iPad)

From **Oct 24 to Nov 1 (the device's local calendar)** M1K3 wears a Halloween look:
the Phosphor Fox glows pumpkin orange, thinks in violet, and greets you in costume
("Happy Halloween from the lair…"). It's a look and a greeting, there's an opt-out in
Settings, and nothing leaves the device. The copy promises exactly that and no more.
Events show on **iPhone and iPad only** (see `../waking-up/README.md`).

**Gate:** the build that carries the Halloween look must be live on the iOS App Store
before this event publishes (17 Oct). Read the store lookup
(`itunes.apple.com/lookup?id=6780230835`) before submitting the event: an event card
for content users can't see breaks the one promise it makes.

## Copy (`event.json`; en-US below, the other nine locales in its `localizations` table, all within the caps by test)

| Field | Cap | Text |
|---|---|---|
| name | 30 | Halloween in the Lair (21) |
| shortDescription | 50 | M1K3 dresses up. Pumpkin glow, villain grin. (44) |
| longDescription | 120 | From Oct 24 to Nov 1, the Phosphor Fox glows pumpkin orange and greets you in costume. A little wicked, all on-device. (118) |

The other locales use a local name for the fox (Phosphorfuchs, zorro fosforescente,
renard phosphorescent, 燐光のキツネ, 인광 여우, raposa fosforescente, 磷光狐狸), since
the app has no localized name for it. The lair is the villain's hideout:
Versteck, guarida, repaire, アジト, 아지트, covil, 老巢. They're drafts by the model and
haven't had a native read.

- **Badge `SPECIAL_EVENT`.** Apple: "Limited-time events that aren't captured by another
  event badge … These events should provide users with new content, features, or goods."
  A seasonal look fits no other badge (`NEW_SEASON` means a new season of content, not a
  calendar season). Apple may judge a cosmetic look thin. If review pushes back, the
  honest answer is the look, the greeting and the dates, not a bigger claim.
- **Purpose `APPROPRIATE_FOR_ALL_USERS`.** It's a look for everyone, new or not.
- **Priority NORMAL**, no purchase, all territories.
- **Deep link `m1k3://event/halloween`.** App Store Connect won't add an event for review without
  one, and Apple's help page takes a custom URL. The iOS target registers `m1k3` from build 521
  (`project.yml`, pinned by `tools/ci/check_store_targets.py`). There's no handler yet: the link
  opens M1K3, and the event (the costume and its greeting) is the chat screen. en-GB reuses the
  en-US copy with day-first dates; es-MX reuses es-ES, since "de oct." breaks the 120 cap.
- **Dates (UTC):** publish 17 Oct 09:00 (7 days ahead; the cap is 14), run 24 Oct 10:00 →
  1 Nov 11:00 (8 days 1 h; the cap is 31).

### UTC times inside every local window

The look runs 24 Oct 00:00 to 1 Nov 23:59:59 on each device's local calendar
(`SeasonalLook.active`), but an event's times are single UTC instants. So `eventStart`
is local midnight on 24 Oct in UTC−10 (Hawaii), later everywhere east, and `eventEnd` is
local midnight on 2 Nov in UTC+13 (New Zealand daylight time), earlier everywhere west:
from UTC−10 to UTC+13 the card is never live where the look isn't. The price is a card
up to 23 hours shorter than the look at each end, starting late in the east and ending
early in the west.

## Art: the Phosphor Fox in costume, as video

Both slots are **video**, which Apple recommends ("consider using video"). Event video autoplays and repeats.

| File | Slot | Format |
|---|---|---|
| `event-card-1920x1080.mp4` | Event card, 16:9 | H.264, 30 fps, 20.5 s, no audio, about 25 MB |
| `event-details-1080x1920.mp4` | Details page, 9:16 | the same |

Each video loops seamlessly. The fox's Survey clip plays exactly six times in 615 frames, and every other
motion completes whole cycles in the same span. Measured, the last frame steps into the first like any
other frame.

The scene uses the site hero's own `Fox.glb`, in the app's Halloween phosphor:

- **The fox:** a PUMPKIN lattice drawn as thick lines over a dark body, with a VIOLET rim. Its EMBER eyes
  ride the head bone.
- **The setting:** the violet CRT floor, under a harvest moon made of the Life field's cells.
- **The bats:** real Life gliders crossing the moon, cut out of its lattice. The renderer refuses to load
  unless four B3/S23 steps move a glider one cell.
- **The embers:** they rise off the floor and cool from ember through pumpkin to violet, like the app's Life cells.

Matching stills sit beside the videos for the nomination and social posts: `event-card-1920x1080.jpg` and
`event-details-1080x1920.jpg` are frame 412, saved as sRGB JPEG at quality 90. The `*-guides.png` proofs
mark the safe area.

The videos are rendered in the private motion project (Remotion, under `marketing/motion`), which isn't in
this repo:

```
npx remotion render src/halloween/index.ts HalloweenCard ../events/halloween/event-card-1920x1080.mp4 \
    --codec=h264 --muted --color-space=bt709 --crf=16
npx remotion render src/halloween/index.ts HalloweenDetails ../events/halloween/event-details-1080x1920.mp4 \
    --codec=h264 --muted --color-space=bt709 --crf=16
```

`events.py create` uploads each slot's video when one is present, and otherwise its still. Before it sends
anything, a dry run included, it checks every video against Apple's media table with `ffprobe`. The first
pass's 2D stills still render as the fallback, but `event_art.py` writes into the art dir by default and
would overwrite the frame-412 stills, so render it elsewhere:
`python3 tools/site/event_art.py --palette halloween --out <scratch dir>` (from `macos/`). The old 2D pair
is kept in the art dir's `previous-2d/`. `event_art.py --check` spec-checks whichever stills are in the art
dir. The palette is the
app's, colour for colour: PUMPKIN `#FF8A1F`, EMBER `#FFB347`, VIOLET `#9B5CFF`, NIGHT `#0A0610`.

**Safe area.** Apple publishes the sizes but no safe area for event media. It says to
keep text and logos out of the art, not to add borders or gradients (it applies its own),
and to check the media in App Store Connect's event preview. The safe area used here is a
third party's field measurement (top 5% on the card or 8% on the details page, bottom 40%,
sides 6%), which also keeps the fox in the upper-centre 60% with the bottom third quiet.
Sources, read 2026-10-11:

- https://developer.apple.com/app-store/in-app-events/ (media guidance; no safe areas)
- https://developer.apple.com/help/app-store-connect/reference/in-app-event-media-and-audio-specifications (sizes, formats, 500 MB)
- https://developer.apple.com/help/app-store-connect/offer-in-app-events/offer-in-app-events (14-day publish lead, 31-day cap)
- https://developer.apple.com/help/app-store-connect/reference/in-app-event-badges (badge definitions)
- https://www.yellowhead.com/blog/in-app-events-promotional-content-safe-zone-guidelines/ (the safe-zone figures; not Apple's)

**UNVERIFIED** until ASC's event preview shows the card and the details page with the
name, badge and description laid over them.

## Ship it (ASC writes are Kev's, via `!`)

```
python3 tools/asc/events.py create --spec fastlane/events/halloween/event.json \
    --art-dir ../marketing/events/halloween --dry-run    # payloads only, no key needed
python3 tools/asc/events.py create --spec fastlane/events/halloween/event.json \
    --art-dir ../marketing/events/halloween              # the DRAFT, 10 locales, art on each
```

The live DRAFT is 6822718507: created 2026-10-14 with eight locales and no deep link. Bring it
up to the spec in this order. `create --event` adds en-GB and es-MX with their video; `update`
then sets the deep link and rewrites every locale's copy. Run the other way round, `update`
would create the two locales with no media and `create --event` would skip them.

```
python3 tools/asc/events.py create --event 6822718507 --spec fastlane/events/halloween/event.json \
    --art-dir ../marketing/events/halloween
python3 tools/asc/events.py update --event 6822718507 --spec fastlane/events/halloween/event.json
```

`create` makes the DRAFT, one localization per locale (en-US first), and uploads the same
textless card and details page to each. If it fails part-way, the DRAFT stays and the
error ends with the line that resumes it (`create … --event <id>`). That run creates only
the locales the event lacks. It skips the ones it has without checking their art, so look
at those in App Store Connect. A plain re-run would make a second event.

Before review, paste `m1k3://event/halloween` into Notes on an iPhone running a build with the
scheme and tap it: Apple's own test, and M1K3 should open. iOS has no approved version yet, so
the event rides the first iOS version's submission (Apple: "include the In-App Event in the
same submission as your first iOS app version"): Add for Review in App Store Connect, then
`tools/asc/submit.py submit --platform ALL --confirm` sends it with the version.

Preview the media under the overlays in App Store Connect first. Events have their own review queue and lock while
in review. Submit early: publishing starts 17 Oct, and the start date can't have passed
when Apple approves it.

<!--
Signed: Kev + claude-opus-5.5, 2026-10-11, Confidence 0.7
Format: MurphySig v0.4 (https://murphysig.dev/spec)
Prior: ../waking-up/README.md (Kev + claude-fable-5.1, 2026-09-15), the shape of this
  file and its spec. The copy is within every cap by test, the art by spec check. Two
  things are Kev's call and stay open: the UTC-vs-local window above, and whether a
  cosmetic look clears Apple's "new content" bar for SPECIAL_EVENT. The non-English
  copy is the model's draft. Open: confirm the app's window includes 1 Nov once its
  Halloween PR lands.
Review: Kev + claude-opus-5.5, 2026-10-11 — review fold: Kev's call on the UTC-vs-local
  window is made (start 24 Oct 10:00Z, end 1 Nov 11:00Z, inside the look from UTC−10 to
  UTC+13, pinned by test), retiring that open; the 1 Nov Open is retired too, since
  SeasonalLook.active matches (10, 24...) and (11, 1). Documented the `--event` resume.
  Still open: the SPECIAL_EVENT bar and a native read of the copy. Confidence 0.8
Review: Kev + claude-opus-5-5, 2026-10-14 — the media is video now (Kev: "we need better assets & videos"):
  a 20.5 s seamless loop per slot of the 3D Phosphor Fox in costume, rendered in the private motion project,
  with matching stills; events.py uploads video when it's there and checks it with ffprobe first. Still open:
  the SPECIAL_EVENT bar, a native read of the copy, and ASC's event preview of the video under the overlays.
  Confidence 0.75
Review: Kev + claude-opus-5-5, 2026-10-14 — the live create worked (8 locales, 16 clips COMPLETE) but App
  Store Connect wouldn't add the event for review without a deep link. The spec gains m1k3://event/halloween
  (the iOS target registers the scheme from build 521) plus en-GB and es-MX, the store's other two locales;
  the live DRAFT's two-step catch-up is above. Kev's preview retires the overlay open ("the event looks
  amazing"). Still open: the SPECIAL_EVENT bar and a native read of the copy. Confidence 0.8
-->
