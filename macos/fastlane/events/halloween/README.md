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

## Copy (`event.json`; en-US below, the other seven locales in its `localizations` table, all within the caps by test)

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
- **Priority NORMAL**, no purchase, all territories, no deep link (the app has no URL scheme).
- **Dates (UTC):** publish 17 Oct 09:00 (7 days ahead; the cap is 14), run 24 Oct 00:00 →
  1 Nov 23:59 (8 days 23 h; the cap is 31).

### The one honest wrinkle: UTC vs. the app's local calendar

The look switches on at local midnight on 24 Oct, but the event's times are UTC. So the
card says "happening now" for a few hours before the costume arrives in the Americas
(US Pacific from 23 Oct 17:00, about 7 h early; Hawaii about 10 h). It also outlives the look at the far
end in Asia-Pacific (Tokyo until 2 Nov 08:59, about 9 h late; New Zealand about 13 h late).
To keep every territory from UTC−10 to UTC+13 inside the look, use
`eventStart 2026-10-24T10:00:00Z` and `eventEnd 2026-11-01T11:00:00Z`. That costs a shorter
card window in the Americas at the end. Kev decides. The current dates are the brief's.
This also assumes the app's window **includes** 1 Nov. If it ends at the start of 1 Nov,
move `eventEnd` back a day.

## Art: rendered from code, textless

```
python3 tools/site/event_art.py --palette halloween --guides    # from macos/
```

This writes `event-card-1920x1080.jpg` (16:9) and `event-details-1080x1920.jpg` (9:16) to
`marketing/events/halloween/` (gitignored, so binaries stay out of the tree), plus
`*-guides.png` proofs. Each proof marks the safe area in green, the overlay bands in red,
and the top of the bottom third with a dashed line. JPEGs are quality 90 and sRGB-tagged,
and the script spec-checks them before it exits. The scene is the store creative's own: the Phosphor Fox from
`site/vendor/Fox.glb` in PUMPKIN strokes (its far flank VIOLET) with an EMBER halo,
standing on a Life field whose cells cool from ember through pumpkin to violet ash. Behind
it is a harvest moon made of the field's own cells. Three Life gliders cross the moon as
bats; they're real gliders (a test steps them through B3/S23), cut out of the moon's lattice.
The palette is the app's, colour for colour: PUMPKIN `#FF8A1F`, EMBER `#FFB347`,
VIOLET `#9B5CFF`, NIGHT `#0A0610`.

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
    --art-dir ../marketing/events/halloween              # the DRAFT, 8 locales, art on each
```

`create` makes the DRAFT, one localization per locale (en-US first), and uploads the same
textless card and details page to each. Then in App Store Connect, preview the media
under the overlays, then Submit for review. Events have their own review queue and lock while
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
-->
