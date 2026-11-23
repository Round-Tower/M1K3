# "Christmas in the Lair": the Christmas & New Year event (in-app event, iPhone + iPad)

The look: `christmas` (Dec 2 – Jan 7, local calendar): candy red at rest, tinsel gold speaking, frost thinking, pine listening. Greeting: "Merry Christmas! I made the nice list this year. Mostly." The event card ends Jan 2 (Apple's 31-day cap), so the copy names no end date.

The "Seasonal looks" opt-out in Settings covers it, and nothing leaves the device. Force it for art or
checks with `-seasonalLook christmas`. The calendar logic is in `Sources/M1K3Avatar/SeasonalLook.swift`,
and why this event exists is in `../CALENDAR.md`.

**Gate:** the build that carries this look (1.6) must be live on the iOS App Store before the event
publishes (2026-11-25T10:00:00Z). Read `itunes.apple.com/lookup?id=6780230835` first. If the look isn't
live yet, move `publishStart` (and `eventStart` if needed): never publish ahead of the build.

Event: 2026-12-02T10:00:00Z → 2027-01-02T09:00:00Z. It starts at 10:00Z, local midnight in UTC−10, so no zone east of
Hawaii sees the card before the look is on. It ends by 10:00Z on the look's last day, local midnight in UTC+14,
so no zone sees the card after the look is off. Deep link: `m1k3://event/christmas`.

## Copy (`event.json`; en-US below, the other eleven locales in its `localizations` table)

| Field | Cap | Text |
|---|---|---|
| name | 30 | Christmas in the Lair (21) |
| shortDescription | 50 | M1K3 dresses up for the holidays. (33) |
| longDescription | 120 | Through Christmas and New Year, the Phosphor Fox glows candy red and gold and greets you with a festive hello. (110) |

Counts are Python `len`. These are drafts by the model; ar-SA and ru need a native read before submission.
